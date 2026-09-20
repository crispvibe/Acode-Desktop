import { promises as fs } from "node:fs";
import path from "node:path";
import {
  chatSessionSnapshotSchema,
  type ChatSessionSnapshot
} from "../../shared/chat.js";

const storeFileName = "chat-sessions.json";

export class ChatSessionStore {
  private readonly filePath: string;

  constructor(userDataPath: string) {
    this.filePath = path.join(userDataPath, storeFileName);
  }

  async load(): Promise<ChatSessionSnapshot> {
    try {
      const raw = await fs.readFile(this.filePath, "utf8");
      return chatSessionSnapshotSchema.parse(JSON.parse(raw));
    } catch (error) {
      if (isMissingFileError(error)) {
        return { sessions: [], sessionMessages: {}, currentSessionId: null };
      }
      throw error;
    }
  }

  async save(snapshot: ChatSessionSnapshot): Promise<boolean> {
    const parsed = chatSessionSnapshotSchema.parse(snapshot);
    await fs.mkdir(path.dirname(this.filePath), { recursive: true });
    const tempPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    await fs.writeFile(tempPath, `${JSON.stringify(parsed, null, 2)}\n`, "utf8");
    await fs.rename(tempPath, this.filePath);
    return true;
  }

  async deleteSession(sessionID: string): Promise<boolean> {
    const snapshot = await this.load();
    const sessionMessages = { ...snapshot.sessionMessages };
    delete sessionMessages[sessionID];
    await this.save({
      sessions: snapshot.sessions.filter((session) => session.id !== sessionID),
      sessionMessages,
      currentSessionId: snapshot.currentSessionId === sessionID ? null : snapshot.currentSessionId ?? null
    });
    return true;
  }
}

function isMissingFileError(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "code" in error && (error as { code: unknown }).code === "ENOENT");
}
