import { DEFAULT_APP_SETTINGS, type AppSettings } from "../../shared/settings.js";
import { SettingsJsonStore } from "./jsonStore.js";

export class AppSettingsService {
  constructor(private readonly store = new SettingsJsonStore()) {}

  read(): Promise<AppSettings> {
    return this.store.read();
  }

  update(rawPatch: unknown): Promise<AppSettings> {
    return this.store.patch(rawPatch);
  }

  reset(): Promise<AppSettings> {
    return this.store.write(DEFAULT_APP_SETTINGS);
  }
}

export { probeCLI } from "./cliProbe.js";
export { SettingsJsonStore } from "./jsonStore.js";
export { CLIProfileService } from "./profileService.js";
export { SafeStorageSecretStore } from "./secretStore.js";
