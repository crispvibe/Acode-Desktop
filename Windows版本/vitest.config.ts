import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import path from "node:path";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@shared": path.resolve(__dirname, "src/shared"),
      "@renderer": path.resolve(__dirname, "src/renderer")
    }
  },
  test: {
    environment: "jsdom",
    setupFiles: [path.resolve(__dirname, "tests/setup.ts")],
    globals: true,
    include: ["tests/**/*.test.ts", "tests/**/*.test.tsx"],
    restoreMocks: true,
    // 附件落盘相关测试共享同一个系统临时目录（含清理整目录的用例），并行跑文件会互相删盘导致偶发失败；
    // 用例总量很小，串行执行文件即可消除该竞争。
    fileParallelism: false
  }
});
