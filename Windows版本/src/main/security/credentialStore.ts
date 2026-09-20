import { app, safeStorage } from "electron";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

const credentialKeySchema = z.string().regex(/^[a-z0-9._-]{3,96}$/i);

const encryptedRecordSchema = z.object({
  version: z.literal(1),
  algorithm: z.literal("electron-safeStorage"),
  ciphertext: z.string().min(1),
  updatedAt: z.string()
});

export class CredentialStoreUnavailableError extends Error {
  constructor() {
    super("Electron safeStorage is not available on this device.");
    this.name = "CredentialStoreUnavailableError";
  }
}

export class CredentialStore {
  private readonly namespace: string;

  constructor(namespace = "remote") {
    this.namespace = credentialKeySchema.parse(namespace);
  }

  async readSecret(key: string): Promise<string | null> {
    const filePath = this.filePath(key);
    let raw: string;
    try {
      raw = await readFile(filePath, "utf8");
    } catch (error) {
      if (isNodeError(error) && error.code === "ENOENT") {
        return null;
      }
      throw error;
    }

    const record = encryptedRecordSchema.parse(JSON.parse(raw));
    return safeStorage.decryptString(Buffer.from(record.ciphertext, "base64"));
  }

  async writeSecret(key: string, value: string): Promise<void> {
    this.assertEncryptionAvailable();
    await mkdir(this.directory(), { recursive: true, mode: 0o700 });
    const encrypted = safeStorage.encryptString(value);
    const record = encryptedRecordSchema.parse({
      version: 1,
      algorithm: "electron-safeStorage",
      ciphertext: encrypted.toString("base64"),
      updatedAt: new Date().toISOString()
    });
    await writeFile(this.filePath(key), `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  }

  async deleteSecret(key: string): Promise<void> {
    await rm(this.filePath(key), { force: true });
  }

  private assertEncryptionAvailable(): void {
    if (!safeStorage.isEncryptionAvailable()) {
      throw new CredentialStoreUnavailableError();
    }
  }

  private directory(): string {
    return path.join(app.getPath("userData"), "secure-store", this.namespace);
  }

  private filePath(key: string): string {
    return path.join(this.directory(), `${credentialKeySchema.parse(key)}.json`);
  }
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}
