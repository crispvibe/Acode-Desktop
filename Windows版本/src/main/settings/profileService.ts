import { randomUUID } from "node:crypto";
import {
  cliProfileCreateInputSchema,
  cliProfileSchema,
  cliProfileUpdateInputSchema,
  cliKindSchema,
  secretFieldSchema,
  type CLIKind,
  type CLIProfile,
  type CLIProfileCreateInput,
  type CLIProfileUpdateInput,
  type SecretField
} from "../../shared/settings.js";
import { SettingsJsonStore } from "./jsonStore.js";
import { SafeStorageSecretStore } from "./secretStore.js";

export interface CLIProfileLaunchSettings {
  executablePath?: string;
  workingDirectory?: string;
  baseUrl?: string;
  env: Record<string, string>;
}

export class CLIProfileService {
  constructor(
    private readonly settingsStore = new SettingsJsonStore(),
    private readonly secretStore = new SafeStorageSecretStore()
  ) {}

  async list(kind?: CLIKind): Promise<CLIProfile[]> {
    const settings = await this.settingsStore.read();
    const parsedKind = kind ? cliKindSchema.parse(kind) : null;
    return parsedKind ? settings.profiles.filter((profile) => profile.kind === parsedKind) : settings.profiles;
  }

  async get(profileId: string): Promise<CLIProfile | null> {
    const settings = await this.settingsStore.read();
    return settings.profiles.find((profile) => profile.id === profileId) ?? null;
  }

  async launchSettings(kind: CLIKind): Promise<CLIProfileLaunchSettings | null> {
    const settings = await this.settingsStore.read();
    const profiles = settings.profiles.filter((profile) => profile.kind === kind && profile.enabled);
    const profile = profiles.find((candidate) => candidate.isDefault) ?? profiles[0] ?? null;
    if (!profile) {
      return null;
    }

    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(profile.env ?? {})) {
      const trimmedKey = key.trim();
      if (trimmedKey && value) {
        env[trimmedKey] = value;
      }
    }

    const baseUrl = trimToUndefined(profile.baseUrl);
    if (baseUrl && profile.kind === "claude" && !env.ANTHROPIC_BASE_URL) {
      env.ANTHROPIC_BASE_URL = baseUrl;
    }
    if (baseUrl && profile.kind === "codex" && !env.OPENAI_BASE_URL) {
      env.OPENAI_BASE_URL = baseUrl;
    }

    if (profile.kind === "claude") {
      const authToken = profile.secretRefs.authToken ? await this.secretStore.getSecret(profile.secretRefs.authToken.id) : null;
      if (authToken && !env.ANTHROPIC_AUTH_TOKEN) {
        env.ANTHROPIC_AUTH_TOKEN = authToken;
      }
    } else {
      const apiKey = profile.secretRefs.apiKey ? await this.secretStore.getSecret(profile.secretRefs.apiKey.id) : null;
      if (apiKey && !env.OPENAI_API_KEY) {
        env.OPENAI_API_KEY = apiKey;
      }
    }

    return {
      executablePath: trimToUndefined(profile.executablePath),
      workingDirectory: trimToUndefined(profile.workingDirectory),
      baseUrl,
      env
    };
  }

  async create(rawInput: unknown): Promise<CLIProfile> {
    const input: CLIProfileCreateInput = cliProfileCreateInputSchema.parse(rawInput);
    const now = new Date().toISOString();
    const settings = await this.settingsStore.update((current) => {
      const hasKindDefault = current.profiles.some((profile) => profile.kind === input.kind && profile.isDefault);
      const profile = cliProfileSchema.parse({
        id: randomUUID(),
        kind: input.kind,
        name: input.name,
        enabled: true,
        isDefault: !hasKindDefault,
        executablePath: input.executablePath,
        baseUrl: input.baseUrl,
        model: input.model,
        permissionMode: input.permissionMode,
        reasoningEffort: input.reasoningEffort,
        workingDirectory: input.workingDirectory,
        env: input.env ?? {},
        secretRefs: {},
        configPath: input.kind === "claude" ? input.configPath : undefined,
        wireApi: input.kind === "codex" ? input.wireApi ?? "auto" : undefined,
        appServer: input.kind === "codex" ? input.appServer ?? {} : undefined,
        createdAt: now,
        updatedAt: now
      });

      return {
        ...current,
        profiles: [...current.profiles, profile]
      };
    });

    const created = settings.profiles.find((profile) => profile.createdAt === now && profile.name === input.name);
    if (!created) {
      throw new Error("Failed to create CLI profile");
    }
    return created;
  }

  async update(profileId: string, rawInput: unknown): Promise<CLIProfile> {
    const input: CLIProfileUpdateInput = cliProfileUpdateInputSchema.parse(rawInput);
    const settings = await this.settingsStore.update((current) => ({
      ...current,
      profiles: current.profiles.map((profile) => {
        if (profile.id !== profileId) {
          return profile;
        }
        return cliProfileSchema.parse({
          ...profile,
          ...input,
          updatedAt: new Date().toISOString()
        });
      })
    }));

    const updated = settings.profiles.find((profile) => profile.id === profileId);
    if (!updated) {
      throw new Error(`CLI profile not found: ${profileId}`);
    }
    return updated;
  }

  async delete(profileId: string): Promise<boolean> {
    const currentSettings = await this.settingsStore.read();
    const removedProfile = currentSettings.profiles.find((profile) => profile.id === profileId) ?? null;
    if (!removedProfile) {
      return false;
    }

    const settings = await this.settingsStore.update((current) => {
      const remaining = current.profiles.filter((profile) => profile.id !== profileId);
      const defaultCandidateIndex = remaining.findIndex((profile) => profile.kind === removedProfile.kind);
      const needsNewDefault = removedProfile.isDefault && defaultCandidateIndex >= 0 && !remaining.some((profile) => profile.kind === removedProfile.kind && profile.isDefault);
      return {
        ...current,
        profiles: needsNewDefault
          ? remaining.map((profile, index) => profile.kind === removedProfile.kind && index === defaultCandidateIndex
            ? { ...profile, isDefault: true, updatedAt: new Date().toISOString() }
            : profile)
          : remaining
      };
    });

    const refs = Object.values(removedProfile.secretRefs);
    await Promise.all(refs.map((ref) => this.secretStore.deleteSecret(ref.id)));
    return !settings.profiles.some((profile) => profile.id === profileId);
  }

  async setDefault(profileId: string): Promise<CLIProfile> {
    let targetKind: CLIKind | null = null;
    const settings = await this.settingsStore.update((current) => {
      const target = current.profiles.find((profile) => profile.id === profileId);
      if (!target) {
        return current;
      }
      targetKind = target.kind;
      const now = new Date().toISOString();
      return {
        ...current,
        defaultCLI: target.kind,
        profiles: current.profiles.map((profile) => profile.kind === target.kind
          ? { ...profile, isDefault: profile.id === profileId, updatedAt: now }
          : profile)
      };
    });

    const selected = settings.profiles.find((profile) => profile.id === profileId);
    if (!selected || !targetKind) {
      throw new Error(`CLI profile not found: ${profileId}`);
    }
    return selected;
  }

  async setProfileSecret(profileId: string, rawField: unknown, plainText: string): Promise<CLIProfile> {
    const field: SecretField = secretFieldSchema.parse(rawField);
    const profile = await this.get(profileId);
    if (!profile) {
      throw new Error(`CLI profile not found: ${profileId}`);
    }

    const previousRef = profile.secretRefs[field];
    const secretRef = await this.secretStore.setSecret({
      id: previousRef?.id,
      label: `${profile.kind}:${profile.name}:${field}`,
      field,
      value: plainText
    });

    return this.update(profileId, {
      secretRefs: {
        ...profile.secretRefs,
        [field]: secretRef
      }
    });
  }

  async clearProfileSecret(profileId: string, rawField: unknown): Promise<CLIProfile> {
    const field: SecretField = secretFieldSchema.parse(rawField);
    const profile = await this.get(profileId);
    if (!profile) {
      throw new Error(`CLI profile not found: ${profileId}`);
    }

    const ref = profile.secretRefs[field];
    if (ref) {
      await this.secretStore.deleteSecret(ref.id);
    }

    const nextRefs = { ...profile.secretRefs };
    delete nextRefs[field];
    return this.update(profileId, { secretRefs: nextRefs });
  }
}

function trimToUndefined(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}
