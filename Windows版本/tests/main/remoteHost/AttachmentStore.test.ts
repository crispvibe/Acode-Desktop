import { access, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import {
  ATTACHMENT_DIRECTORY_NAME,
  attachmentRootDirectory,
  cleanupAttachmentStore,
  sanitizeFilename,
  storeUploadedAttachment
} from "../../../src/main/remoteHost/AttachmentStore";

const base64 = (text: string): string => Buffer.from(text, "utf8").toString("base64");

describe("AttachmentStore.sanitizeFilename", () => {
  it("takes the basename and strips path separators / dangerous chars", () => {
    expect(sanitizeFilename("/etc/passwd")).toBe("passwd");
    expect(sanitizeFilename("..\\..\\windows\\system32\\x.png")).toBe("x.png");
    expect(sanitizeFilename("a:b\nc.png")).toBe("a_b_c.png");
  });

  it("falls back to a default when empty", () => {
    expect(sanitizeFilename("   ")).toBe("attachment");
    expect(sanitizeFilename("/tmp/")).toBe("attachment");
  });
});

describe("AttachmentStore.storeUploadedAttachment", () => {
  afterAll(async () => {
    await rm(path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME), { recursive: true, force: true });
  });

  it("writes a valid attachment to the temp dir and returns its absolute path", async () => {
    const content = "hello attachment";
    const result = await storeUploadedAttachment("note.txt", base64(content));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.filename).toBe("note.txt");
    expect(result.value.path.startsWith(path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME))).toBe(true);
    await expect(readFile(result.value.path, "utf8")).resolves.toBe(content);
  });

  it("accepts whitelisted image extensions", async () => {
    const result = await storeUploadedAttachment("photo.png", base64("png-bytes"));
    expect(result.ok).toBe(true);
  });

  it("rejects content over the size limit", async () => {
    const result = await storeUploadedAttachment("big.png", base64("hello world"), 4);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe("attachment_too_large");
    expect(result.error.statusCode).toBe(413);
  });

  it("rejects malformed base64", async () => {
    const result = await storeUploadedAttachment("note.txt", "!!!notbase64!!!");
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe("invalid_content");
  });

  it("rejects disallowed extensions", async () => {
    const result = await storeUploadedAttachment("malware.exe", base64("MZ"));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe("attachment_type_not_allowed");
    expect(result.error.statusCode).toBe(415);
  });

  it("allows extension-less text files", async () => {
    const result = await storeUploadedAttachment("LICENSE", base64("MIT"));
    expect(result.ok).toBe(true);
  });

  it("cleanupAttachmentStore removes the whole root directory", async () => {
    const stored = await storeUploadedAttachment("cleanup.txt", base64("bye"));
    expect(stored.ok).toBe(true);
    if (!stored.ok) return;
    await expect(access(stored.value.path)).resolves.toBeUndefined();

    await cleanupAttachmentStore();

    await expect(access(stored.value.path)).rejects.toBeTruthy();
    await expect(access(attachmentRootDirectory())).rejects.toBeTruthy();
  });

  it("cleanupAttachmentStore is a no-op when nothing was uploaded", async () => {
    await expect(cleanupAttachmentStore()).resolves.toBeUndefined();
  });
});
