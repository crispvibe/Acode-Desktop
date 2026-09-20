import { StringDecoder } from "node:string_decoder";

export type JSONLChunk = Buffer | Uint8Array | string;

export interface JSONLReaderOptions {
  maxLineBytes?: number;
}

const newline = "\n";
const carriageReturnPattern = /\r/g;

export async function* readJSONLLines(
  chunks: AsyncIterable<JSONLChunk>,
  options: JSONLReaderOptions = {}
): AsyncGenerator<string> {
  const maxLineBytes = options.maxLineBytes ?? 1024 * 1024;
  const decoder = new StringDecoder("utf8");
  let buffer = "";

  for await (const chunk of chunks) {
    buffer += typeof chunk === "string" ? chunk : decoder.write(Buffer.from(chunk));

    let newlineIndex = buffer.indexOf(newline);
    while (newlineIndex >= 0) {
      const line = buffer.slice(0, newlineIndex).replace(carriageReturnPattern, "");
      if (Buffer.byteLength(line) > maxLineBytes) {
        throw new Error(`JSONL line exceeded ${maxLineBytes} bytes`);
      }
      buffer = buffer.slice(newlineIndex + 1);
      if (line.length > 0) {
        yield line;
      }
      newlineIndex = buffer.indexOf(newline);
    }

    if (Buffer.byteLength(buffer) > maxLineBytes) {
      throw new Error(`JSONL line exceeded ${maxLineBytes} bytes`);
    }
  }

  buffer += decoder.end();
  const tail = buffer.replace(carriageReturnPattern, "");
  if (Buffer.byteLength(tail) > maxLineBytes) {
    throw new Error(`JSONL line exceeded ${maxLineBytes} bytes`);
  }
  if (tail.length > 0) {
    yield tail;
  }
}

export async function* parseJSONLStream<T = unknown>(
  chunks: AsyncIterable<JSONLChunk>,
  options: JSONLReaderOptions = {}
): AsyncGenerator<T> {
  for await (const line of readJSONLLines(chunks, options)) {
    yield JSON.parse(line) as T;
  }
}
