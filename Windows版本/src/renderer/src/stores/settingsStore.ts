import { create } from "zustand";
import type { AppInfo } from "@shared/ipc";
import type {
  AppSettings,
  AppSettingsUpdate,
  CLIKind,
  CLIProbeResult,
  CLIProfile,
  CLIProfileCreateInput,
  CLIProfileUpdateInput,
  SecretField
} from "@shared/settings";

interface SettingsBridgeApi {
  get: () => Promise<AppSettings>;
  update: (patch: AppSettingsUpdate) => Promise<AppSettings>;
  reset: () => Promise<AppSettings>;
  profiles: {
    list: (kind?: CLIKind) => Promise<CLIProfile[]>;
    create: (input: CLIProfileCreateInput) => Promise<CLIProfile>;
    update: (profileId: string, input: CLIProfileUpdateInput) => Promise<CLIProfile>;
    remove: (profileId: string) => Promise<boolean>;
    setDefault: (profileId: string) => Promise<CLIProfile>;
    setSecret: (profileId: string, field: SecretField, value: string) => Promise<CLIProfile>;
    clearSecret: (profileId: string, field: SecretField) => Promise<CLIProfile>;
  };
  probe: (kind: CLIKind, command?: string) => Promise<CLIProbeResult>;
  addAuthorizedFolder: () => Promise<AppSettings>;
  removeAuthorizedFolder: (folderId: string) => Promise<AppSettings>;
}

interface CodevokeSettingsWindow extends Window {
  codevoke?: Window["codevoke"] & {
    settings?: SettingsBridgeApi;
  };
}

interface SettingsState {
  settings: AppSettings | null;
  loading: boolean;
  saving: boolean;
  error: string | null;
  appInfo: AppInfo | null;
  lastProbe: CLIProbeResult | null;
  load: () => Promise<void>;
  loadAppInfo: () => Promise<void>;
  savePatch: (patch: AppSettingsUpdate) => Promise<void>;
  reset: () => Promise<void>;
  createProfile: (input: CLIProfileCreateInput) => Promise<void>;
  updateProfile: (profileId: string, input: CLIProfileUpdateInput) => Promise<void>;
  deleteProfile: (profileId: string) => Promise<void>;
  setDefaultProfile: (profileId: string) => Promise<void>;
  setProfileSecret: (profileId: string, field: SecretField, value: string) => Promise<void>;
  clearProfileSecret: (profileId: string, field: SecretField) => Promise<void>;
  probeCLI: (kind: CLIKind, command?: string) => Promise<void>;
  addAuthorizedFolder: () => Promise<void>;
  removeAuthorizedFolder: (folderId: string) => Promise<void>;
}

export const useSettingsStore = create<SettingsState>((set, get) => ({
  settings: null,
  loading: false,
  saving: false,
  error: null,
  appInfo: null,
  lastProbe: null,

  async load() {
    set({ loading: true, error: null });
    try {
      const settings = await getSettingsBridge().get();
      set({ settings, loading: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), loading: false });
    }
  },

  async loadAppInfo() {
    try {
      const appInfo = await getAppBridge().getAppInfo();
      set({ appInfo });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error) });
    }
  },

  async savePatch(patch) {
    set({ saving: true, error: null });
    try {
      const settings = await getSettingsBridge().update(patch);
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async reset() {
    set({ saving: true, error: null });
    try {
      const settings = await getSettingsBridge().reset();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async createProfile(input) {
    set({ saving: true, error: null });
    try {
      await getSettingsBridge().profiles.create(input);
      const settings = await getSettingsBridge().get();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async updateProfile(profileId, input) {
    set({ saving: true, error: null });
    try {
      await getSettingsBridge().profiles.update(profileId, input);
      const settings = await getSettingsBridge().get();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async deleteProfile(profileId) {
    set({ saving: true, error: null });
    try {
      await getSettingsBridge().profiles.remove(profileId);
      const settings = await getSettingsBridge().get();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async setDefaultProfile(profileId) {
    set({ saving: true, error: null });
    try {
      await getSettingsBridge().profiles.setDefault(profileId);
      const settings = await getSettingsBridge().get();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async setProfileSecret(profileId, field, value) {
    set({ saving: true, error: null });
    try {
      await getSettingsBridge().profiles.setSecret(profileId, field, value);
      const settings = await getSettingsBridge().get();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async clearProfileSecret(profileId, field) {
    set({ saving: true, error: null });
    try {
      await getSettingsBridge().profiles.clearSecret(profileId, field);
      const settings = await getSettingsBridge().get();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async probeCLI(kind, command) {
    set({ saving: true, error: null });
    try {
      const result = await getSettingsBridge().probe(kind, command);
      set({ lastProbe: result, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async addAuthorizedFolder() {
    set({ saving: true, error: null });
    try {
      const settings = await getSettingsBridge().addAuthorizedFolder();
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  },

  async removeAuthorizedFolder(folderId) {
    set({ saving: true, error: null });
    try {
      const settings = await getSettingsBridge().removeAuthorizedFolder(folderId);
      set({ settings, saving: false });
    } catch (error: unknown) {
      set({ error: toErrorMessage(error), saving: false });
    }
  }
}));

export function selectProfiles(settings: AppSettings | null, kind: CLIKind): CLIProfile[] {
  return settings?.profiles.filter((profile) => profile.kind === kind) ?? [];
}

function getSettingsBridge(): SettingsBridgeApi {
  const api = getAppBridge().settings;
  if (!api) {
    throw new Error("window.codevoke.settings bridge is not available");
  }
  return api;
}

function getAppBridge(): NonNullable<CodevokeSettingsWindow["codevoke"]> {
  const api = (window as CodevokeSettingsWindow).codevoke;
  if (!api) {
    throw new Error("window.codevoke bridge is not available");
  }
  return api;
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
