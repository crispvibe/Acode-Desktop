// @vitest-environment node

import { describe, expect, it } from "vitest";
import { parseJSONLStream, readJSONLLines, type JSONLChunk } from "../../../src/main/chat/jsonlReader";

async function collectLines(chunks: JSONLChunk[], maxLineBytes?: number): Promise<string[]> {
  return Array.fromAsync(readJSONLLines(chunks, maxLineBytes ? { maxLineBytes } : undefined));
}

describe("readJSONLLines", () => {
  it("preserves UTF-8 characters split across chunks", async () => {
    const bytes = Buffer.from('{"text":"你好🙂"}\n{"text":"done"}\n', "utf8");
    const lines = await collectLines([
      bytes.subarray(0, 11),
      bytes.subarray(11, 17),
      bytes.subarray(17)
    ]);

    expect(lines).toEqual(['{"text":"你好🙂"}', '{"text":"done"}']);
  });

  it("normalizes CRLF and yields trailing half-lines at EOF", async () => {
    const lines = await collectLines(["{\"a\":1}\r\n{\"b\":2}"]);

    expect(lines).toEqual(['{"a":1}', '{"b":2}']);
  });

  it("skips empty lines", async () => {
    const lines = await collectLines(["\n{\"ok\":true}\n\n"]);

    expect(lines).toEqual(['{"ok":true}']);
  });

  it("rejects lines exceeding the configured byte limit", async () => {
    await expect(collectLines(["123456\n"], 5)).rejects.toThrow("JSONL line exceeded 5 bytes");
  });
});

describe("parseJSONLStream", () => {
  it("parses each JSONL object", async () => {
    const values = await Array.fromAsync(parseJSONLStream<{ id: number }>(["{\"id\":1}\n{\"id\":2}\n"]));

    expect(values).toEqual([{ id: 1 }, { id: 2 }]);
  });
});
