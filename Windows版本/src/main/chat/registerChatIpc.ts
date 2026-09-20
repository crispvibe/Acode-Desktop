import { ipcMain, type WebContents } from "electron";
import {
  chatSessionSnapshotSchema,
  chatInteractiveResponseRequestSchema,
  chatPermissionResponseRequestSchema,
  chatRunIDRequestSchema,
  chatStartRequestSchema,
  type ChatBackendEvent,
  type ChatStartRequest
} from "../../shared/chat.js";
import { ipcChannels } from "../../shared/ipc.js";
import { ChatSessionStore } from "./chatSessionStore.js";
import { ChatProcessRun } from "./processChatBackend.js";
import { CLIProfileService } from "../settings/profileService.js";
import { resolveExistingDirectory } from "../security/pathGuards.js";

const activeRuns = new Map<string, ChatProcessRun>();

export function registerChatIpcHandlers(sessionStore?: ChatSessionStore, profileService?: CLIProfileService): void {
  ipcMain.handle(ipcChannels.chatStart, async (event, rawRequest: unknown) => {
    const parsedRequest = chatStartRequestSchema.parse(rawRequest) as ChatStartRequest;
    const request = await applyProfileLaunchSettings(parsedRequest, profileService);
    if (activeRuns.has(request.runID)) {
      throw new Error(`Chat run already exists: ${request.runID}`);
    }

    const run = new ChatProcessRun(request, (chatEvent) => {
      sendChatEvent(event.sender, request.runID, chatEvent);
    });
    activeRuns.set(request.runID, run);
    void run.start().finally(() => {
      activeRuns.delete(request.runID);
    });
    return { runID: request.runID };
  });

  ipcMain.handle(ipcChannels.chatInterrupt, async (_event, rawRequest: unknown) => {
    const request = chatRunIDRequestSchema.parse(rawRequest);
    const run = activeRuns.get(request.runID);
    if (!run) {
      return false;
    }
    run.interrupt();
    return true;
  });

  ipcMain.handle(ipcChannels.chatPermissionResponse, async (_event, rawRequest: unknown) => {
    const request = chatPermissionResponseRequestSchema.parse(rawRequest);
    return activeRuns.get(request.runID)?.respondToPermission(request.requestID, request.decision) ?? false;
  });

  ipcMain.handle(ipcChannels.chatInteractiveResponse, async (_event, rawRequest: unknown) => {
    const request = chatInteractiveResponseRequestSchema.parse(rawRequest);
    return activeRuns.get(request.runID)?.respondToInteractiveRequest(request.response) ?? false;
  });

  ipcMain.handle(ipcChannels.chatCompact, async (_event, rawRequest: unknown) => {
    const request = chatRunIDRequestSchema.parse(rawRequest);
    return activeRuns.get(request.runID)?.sendCompact() ?? false;
  });

  if (sessionStore) {
    ipcMain.handle(ipcChannels.chatSessionLoad, async () => sessionStore.load());

    ipcMain.handle(ipcChannels.chatSessionSave, async (_event, rawSnapshot: unknown) =>
      sessionStore.save(chatSessionSnapshotSchema.parse(rawSnapshot))
    );

    ipcMain.handle(ipcChannels.chatSessionDelete, async (_event, rawSessionID: unknown) =>
      sessionStore.deleteSession(chatRunIDOrSessionID(rawSessionID))
    );
  }
}

async function applyProfileLaunchSettings(request: ChatStartRequest, profileService?: CLIProfileService): Promise<ChatStartRequest> {
  const launchSettings = await profileService?.launchSettings(request.options.cli);
  if (!launchSettings) {
    return request;
  }

  const workingDirectory = launchSettings.workingDirectory
    ? (await resolveExistingDirectory(launchSettings.workingDirectory)).realPath
    : null;

  return {
    ...request,
    options: {
      ...request.options,
      executablePath: launchSettings.executablePath ?? request.options.executablePath,
      workingDirectory,
      baseURL: launchSettings.baseUrl ?? null,
      environment: launchSettings.env
    }
  };
}

function chatRunIDOrSessionID(rawValue: unknown): string {
  if (typeof rawValue === "string" && rawValue.trim()) {
    return rawValue;
  }
  if (rawValue && typeof rawValue === "object" && "sessionID" in rawValue) {
    const sessionID = (rawValue as { sessionID: unknown }).sessionID;
    if (typeof sessionID === "string" && sessionID.trim()) {
      return sessionID;
    }
  }
  throw new Error("Invalid chat session id.");
}

function sendChatEvent(sender: WebContents, runID: string, event: ChatBackendEvent): void {
  if (sender.isDestroyed()) {
    return;
  }
  sender.send(ipcChannels.chatEvent, { runID, event });
}
