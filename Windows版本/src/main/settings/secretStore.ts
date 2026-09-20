import { app, safeStorage } from "electron";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { secretFieldSchema, type SecretField, type SecretValueRef } from "../../shared/settings.js";

const storedSecretSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  field: secretFieldSchema,
  encryptedValue: z.string().min(1),
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1)
});

const secretFileSchema = z.object({
  schemaVersion: z.literal(1).default(1),
  secrets: z.record(storedSecretSchema).default({})
});

type SecretFile = z.infer<typeof secretFileSchema>;
type StoredSecret = z.infer<typeof storedSecretSchema>;

export class SafeStorageSecretStore {
  readonly filePath: string;

  constructor(filePath = path.join(app.getPath("userData"), "settings-secrets.json")) {
    this.filePath = filePath;
  }

  isEncryptionAvailable(): boolean {
    return safeStorage.isEncryptionAvailable();
  }

  async setSecret(input: {
    id?: string;
    label: string;
    field: SecretField;
    value: string;
  }): Promise<SecretValueRef> {
    this.assertEncryptionAvailable();
    const file = await this.readFile();
    const now = new Date().toISOString();
    const id = input.id ?? randomUUID();
    const previous = file.secrets[id];
    const secret: StoredSecret = {
      id,
      label: input.label,
      field: input.field,
      encryptedValue: safeStorage.encryptString(input.value).toString("base64"),
      createdAt: previous?.createdAt ?? now,
      updatedAt: now
    };
    file.secrets[id] = secret;
    await this.writeFile(file);
    return toSecretValueRef(secret);
  }

  async getSecret(id: string): Promise<string | null> {
    this.assertEncryptionAvailable();
    const file = await this.readFile();
    const secret = file.secrets[id];
    if (!secret) {
      return null;
    }
    return safeStorage.decryptString(Buffer.from(secret.encryptedValue, "base64"));
  }

  async deleteSecret(id: string): Promise<boolean> {
    const file = await this.readFile();
    if (!file.secrets[id]) {
      return false;
    }
    delete file.secrets[id];
    await this.writeFile(file);
    return true;
  }

  async listSecretRefs(): Promise<SecretValueRef[]> {
    const file = await this.readFile();
    return Object.values(file.secrets).map(toSecretValueRef);
  }

  private assertEncryptionAvailable(): void {
    if (!safeStorage.isEncryptionAvailable()) {
      throw new Error("Electron safeStorage encryption is not available on this device");
    }
  }

  private async readFile(): Promise<SecretFile> {
    try {
      const content = await readFile(this.filePath, "utf8");
      const parsed: unknown = JSON.parse(content);
      return secretFileSchema.parse(parsed);
    } catch (error: unknown) {
      if (isNodeError(error) && error.code === "ENOENT") {
        return secretFileSchema.parse({});
      }
      throw error;
    }
  }

  private async writeFile(file: SecretFile): Promise<void> {
    const normalized = secretFileSchema.parse(file);
    await mkdir(path.dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
    await rename(temporaryPath, this.filePath);
  }
}

function toSecretValueRef(secret: StoredSecret): SecretValueRef {
  return {
    id: secret.id,
    label: secret.label,
    updatedAt: secret.updatedAt
  };
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}
