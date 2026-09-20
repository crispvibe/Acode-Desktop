import {
  ChevronLeft,
  Copy,
  Cpu,
  FileText,
  Folder,
  Info,
  Monitor,
  RefreshCw,
  RotateCcw,
  Save,
  Settings,
  Terminal,
  Trash2
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type {
  AppSettings,
  CLIKind,
  CLIProfile,
  CLIProfileUpdateInput,
  CLIWireApi,
  GlobalRuleTarget,
  PermissionMode,
  ReasoningEffort,
  SecretField,
  WindowsShell,
  WindowsTerminal
} from "@shared/settings";
import type { RemoteHostStatus } from "@shared/ipc";
import { AppLogo } from "../AppLogo";
import { selectProfiles, useSettingsStore } from "../../stores/settingsStore";

type SettingsTabID =
  | "general"
  | "claude"
  | "codex"
  | "remoteChat"
  | "appendRules"
  | "globalRules"
  | "about";

interface SettingsPageProps {
  onBack?: () => void;
}

const tabs = [
  { id: "general", title: "通用", icon: Settings },
  { id: "claude", title: "Claude Code", icon: Terminal },
  { id: "codex", title: "Codex", icon: Cpu },
  { id: "remoteChat", title: "设备连接", icon: Monitor },
  { id: "appendRules", title: "追加规则", icon: FileText },
  { id: "globalRules", title: "全局规则", icon: Copy },
  { id: "about", title: "关于与版本", icon: Info }
] satisfies Array<{ id: SettingsTabID; title: string; icon: typeof Settings }>;

const permissionModeOptions: Array<{ value: PermissionMode; label: string }> = [
  { value: "default", label: "默认" },
  { value: "plan", label: "计划" },
  { value: "acceptEdits", label: "接受编辑" },
  { value: "bypassPermissions", label: "绕过权限" }
];

const reasoningEffortOptions: Array<{ value: ReasoningEffort; label: string }> = [
  { value: "minimal", label: "Minimal" },
  { value: "low", label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high", label: "High" }
];

const terminalOptions: Array<{ value: WindowsTerminal; label: string }> = [
  { value: "windowsTerminal", label: "Windows Terminal" },
  { value: "powershell", label: "PowerShell" },
  { value: "cmd", label: "Command Prompt" },
  { value: "gitBash", label: "Git Bash" }
];

const shellOptions: Array<{ value: WindowsShell; label: string }> = [
  { value: "powershell", label: "PowerShell" },
  { value: "cmd", label: "Command Prompt" },
  { value: "gitBash", label: "Git Bash" }
];

const wireApiOptions: Array<{ value: CLIWireApi; label: string }> = [
  { value: "auto", label: "Auto" },
  { value: "responses", label: "Responses" },
  { value: "chatCompletions", label: "Chat Completions" }
];

export function SettingsPage({ onBack }: SettingsPageProps = {}) {
  const [selectedTab, setSelectedTab] = useState<SettingsTabID>("general");
  const settings = useSettingsStore((state) => state.settings);
  const loading = useSettingsStore((state) => state.loading);
  const saving = useSettingsStore((state) => state.saving);
  const error = useSettingsStore((state) => state.error);
  const load = useSettingsStore((state) => state.load);
  const reset = useSettingsStore((state) => state.reset);

  useEffect(() => {
    if (!settings && !loading) {
      void load();
    }
  }, [load, loading, settings]);

  const selectedItem = tabs.find((item) => item.id === selectedTab) ?? tabs[0];

  return (
    <section className="settings-shell">
      <aside className="settings-sidebar glass-panel">
        <h2>设置</h2>
        <div className="settings-nav">
          {tabs.map((item) => {
            const Icon = item.icon;
            return (
              <button
                className={`settings-nav-row ${item.id === selectedTab ? "selected" : ""}`}
                key={item.id}
                type="button"
                onClick={() => setSelectedTab(item.id)}
              >
                <span className="settings-nav-icon">
                  <Icon size={16} />
                </span>
                <span>{item.title}</span>
              </button>
            );
          })}
        </div>
        <div className="settings-sidebar-footer">
          {onBack ? (
            <button className="back-button settings-back-button" type="button" onClick={onBack}>
              <ChevronLeft size={15} />
              <span>返回工作台</span>
            </button>
          ) : null}
          <button className="back-button" type="button" onClick={() => void reset()}>
            <RotateCcw size={15} />
            <span>恢复默认</span>
          </button>
        </div>
      </aside>

      <section className="settings-content">
        <h1>{selectedItem.title}</h1>
        {error ? <div className="settings-card">{error}</div> : null}
        {saving ? <p className="hint">保存中...</p> : null}
        {!settings ? <SettingsLoading loading={loading} /> : (
          <SettingsTabContent selectedTab={selectedTab} settings={settings} />
        )}
      </section>
    </section>
  );
}

function SettingsLoading({ loading }: { loading: boolean }) {
  const load = useSettingsStore((state) => state.load);

  return (
    <div className="settings-card">
      <p>{loading ? "正在载入设置..." : "设置桥接尚未接入。"}</p>
      <button className="settings-primary-button" type="button" onClick={() => void load()}>
        <RefreshCw size={14} /> 重新载入
      </button>
    </div>
  );
}

function SettingsTabContent({
  selectedTab,
  settings
}: {
  selectedTab: SettingsTabID;
  settings: AppSettings;
}) {
  switch (selectedTab) {
    case "claude":
      return <ProfileSettings kind="claude" settings={settings} />;
    case "codex":
      return <ProfileSettings kind="codex" settings={settings} />;
    case "remoteChat":
      return <RemoteChatSettings />
    case "appendRules":
      return <AppendRulesSettings settings={settings} />;
    case "globalRules":
      return <GlobalRulesSettings settings={settings} />;
    case "about":
      return <AboutSettings />;
    case "general":
    default:
      return <GeneralSettings settings={settings} />;
  }
}

function GeneralSettings({ settings }: { settings: AppSettings }) {
  const savePatch = useSettingsStore((state) => state.savePatch);
  const [ignoredFolders, setIgnoredFolders] = useState(settings.ignoredFolders.join("\n"));

  useEffect(() => {
    setIgnoredFolders(settings.ignoredFolders.join("\n"));
  }, [settings.ignoredFolders]);

  return (
    <div className="settings-stack">
      <div className="settings-card">
        <div className="settings-grid">
          <SettingsSelect
            label="默认 CLI"
            value={settings.defaultCLI}
            options={[
              { value: "claude", label: "Claude Code" },
              { value: "codex", label: "Codex" }
            ]}
            onChange={(value) => void savePatch({ defaultCLI: value as CLIKind })}
          />
          <SettingsSelect
            label="默认终端"
            value={settings.terminal}
            options={terminalOptions}
            onChange={(value) => void savePatch({ terminal: value as WindowsTerminal })}
          />
          <SettingsSelect
            label="Shell"
            value={settings.shell}
            options={shellOptions}
            onChange={(value) => void savePatch({ shell: value as WindowsShell })}
          />
          <SettingsSelect
            label="权限模式"
            value={settings.permissionMode}
            options={permissionModeOptions}
            onChange={(value) => void savePatch({ permissionMode: value as PermissionMode })}
          />
          <SettingsSelect
            label="推理强度"
            value={settings.reasoningEffort}
            options={reasoningEffortOptions}
            onChange={(value) => void savePatch({ reasoningEffort: value as ReasoningEffort })}
          />
          <label>
            <span className="settings-label">默认模型</span>
            <input
              className="settings-input"
              defaultValue={settings.model}
              placeholder="例如 gpt-5.4 / claude-opus"
              onBlur={(event) => void savePatch({ model: event.currentTarget.value.trim() })}
            />
          </label>
        </div>

        <label className="settings-label" htmlFor="settings-ignored-folders">忽略目录</label>
        <textarea
          id="settings-ignored-folders"
          className="settings-textarea"
          value={ignoredFolders}
          onBlur={() => void savePatch({
            ignoredFolders: ignoredFolders.split(/\r?\n/).map((item) => item.trim()).filter(Boolean)
          })}
          onChange={(event) => setIgnoredFolders(event.currentTarget.value)}
        />
        <p className="hint">每行一个目录名。</p>

        <AuthorizedFolders settings={settings} />
      </div>
    </div>
  );
}

function AuthorizedFolders({ settings }: { settings: AppSettings }) {
  const saving = useSettingsStore((state) => state.saving);
  const addAuthorizedFolder = useSettingsStore((state) => state.addAuthorizedFolder);
  const removeAuthorizedFolder = useSettingsStore((state) => state.removeAuthorizedFolder);

  return (
    <>
      <div className="authorized-header">
        <div>
          <h3>授权文件夹</h3>
          <p>添加后可通过编辑器打开和保存该目录下的文件；路径选择和校验由主进程完成。</p>
        </div>
        <button type="button" disabled={saving} onClick={() => void addAuthorizedFolder()}>添加文件夹</button>
      </div>
      {settings.authorizedFolders.length === 0 ? (
        <p>尚未添加授权文件夹。</p>
      ) : settings.authorizedFolders.map((folder) => (
        <div className="authorized-row" key={folder.id}>
          <Folder size={17} />
          <div>
            <b>{folder.name}</b>
            <span>{folder.path}</span>
          </div>
          <button type="button" disabled={saving} onClick={() => void removeAuthorizedFolder(folder.id)}>移除</button>
        </div>
      ))}
    </>
  );
}

function ProfileSettings({ kind, settings }: { kind: CLIKind; settings: AppSettings }) {
  const profiles = useMemo(() => selectProfiles(settings, kind), [kind, settings]);
  const createProfile = useSettingsStore((state) => state.createProfile);
  const probeCLI = useSettingsStore((state) => state.probeCLI);
  const lastProbe = useSettingsStore((state) => state.lastProbe);
  const [newName, setNewName] = useState(kind === "claude" ? "Claude 中转站" : "Codex 配置");
  const isClaude = kind === "claude";

  return (
    <div className="settings-stack">
      <div className="settings-card">
        <div className="settings-card-intro">
          <h3>{isClaude ? "Claude Code 中转站列表" : "Codex 中转站列表"}</h3>
          <p>
            {isClaude
              ? "列表管理 API 地址、模型、命令路径和 Auth Token 引用；明文只会提交给 main 进程保存。"
              : "列表管理 base_url、模型、命令路径和 API Key 引用；wire_api/app-server 网络监听暂未接入，不会伪造生效状态。"}
          </p>
        </div>
        <div className="settings-actions">
          <input className="settings-input" value={newName} onChange={(event) => setNewName(event.currentTarget.value)} />
          <button
            className="settings-primary-button"
            type="button"
            onClick={() => void createProfile({ kind, name: newName.trim() || `${kind} profile` })}
          >
            新建
          </button>
          <button type="button" className="settings-inline-button" onClick={() => void probeCLI(kind)}>
            <RefreshCw size={14} /> 探测 CLI
          </button>
        </div>
      </div>

      {profiles.length === 0 ? (
        <div className="settings-card">
          <p>{isClaude ? "还没有 Claude Code 配置。" : "还没有 Codex 配置。"}</p>
        </div>
      ) : profiles.map((profile) => (
        <ProfileEditor key={profile.id} profile={profile} />
      ))}

      {lastProbe?.kind === kind ? (
        <div className="settings-card">
          <div className="settings-row"><span>命令</span><code>{lastProbe.command}</code></div>
          <div className="settings-row"><span>路径</span><code>{lastProbe.resolvedPath ?? "未找到"}</code></div>
          <div className="settings-row"><span>版本</span><code>{firstLine(lastProbe.version) ?? "无"}</code></div>
          {kind === "codex" ? (
            <div className="settings-row">
              <span>app-server</span>
              <b>{lastProbe.capabilities.appServer ? "支持" : "未发现"}</b>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function ProfileEditor({ profile }: { profile: CLIProfile }) {
  const updateProfile = useSettingsStore((state) => state.updateProfile);
  const deleteProfile = useSettingsStore((state) => state.deleteProfile);
  const setDefaultProfile = useSettingsStore((state) => state.setDefaultProfile);
  const [name, setName] = useState(profile.name);
  const [executablePath, setExecutablePath] = useState(profile.executablePath ?? "");
  const [baseUrl, setBaseUrl] = useState(profile.baseUrl ?? "");
  const [model, setModel] = useState(profile.model ?? "");
  const [workingDirectory, setWorkingDirectory] = useState(profile.workingDirectory ?? "");
  const [configPath, setConfigPath] = useState(profile.kind === "claude" ? profile.configPath ?? "" : "");
  const [permissionMode, setPermissionMode] = useState<PermissionMode>(profile.permissionMode ?? "default");
  const [reasoningEffort, setReasoningEffort] = useState<ReasoningEffort>(profile.reasoningEffort ?? "medium");
  const [wireApi, setWireApi] = useState<CLIWireApi>(profile.kind === "codex" ? profile.wireApi : "auto");
  const [appServerEnabled, setAppServerEnabled] = useState(profile.kind === "codex" ? profile.appServer.enabled : false);
  const [appServerHost, setAppServerHost] = useState(profile.kind === "codex" ? profile.appServer.host : "127.0.0.1");
  const [appServerPort, setAppServerPort] = useState(profile.kind === "codex" ? profile.appServer.port?.toString() ?? "" : "");

  useEffect(() => {
    setName(profile.name);
    setExecutablePath(profile.executablePath ?? "");
    setBaseUrl(profile.baseUrl ?? "");
    setModel(profile.model ?? "");
    setWorkingDirectory(profile.workingDirectory ?? "");
    setConfigPath(profile.kind === "claude" ? profile.configPath ?? "" : "");
    setPermissionMode(profile.permissionMode ?? "default");
    setReasoningEffort(profile.reasoningEffort ?? "medium");
    setWireApi(profile.kind === "codex" ? profile.wireApi : "auto");
    setAppServerEnabled(profile.kind === "codex" ? profile.appServer.enabled : false);
    setAppServerHost(profile.kind === "codex" ? profile.appServer.host : "127.0.0.1");
    setAppServerPort(profile.kind === "codex" ? profile.appServer.port?.toString() ?? "" : "");
  }, [profile]);

  function saveProfile() {
    const update: CLIProfileUpdateInput = {
      name: name.trim() || profile.name,
      executablePath: emptyToUndefined(executablePath),
      baseUrl: emptyToUndefined(baseUrl),
      model: emptyToUndefined(model),
      permissionMode,
      reasoningEffort,
      workingDirectory: emptyToUndefined(workingDirectory)
    };

    if (profile.kind === "claude") {
      update.configPath = emptyToUndefined(configPath);
    }

    void updateProfile(profile.id, update);
  }

  return (
    <div className={`settings-card ${profile.isDefault ? "selected" : ""}`}>
      <div className="settings-card-intro">
        <h3>{profile.kind === "claude" ? "Claude Code Profile" : "Codex Profile"}</h3>
        <p>{profile.isDefault ? "当前默认配置" : "保存后可设为当前配置。"}</p>
      </div>
      <div className="settings-grid">
        <TextInput label="名称" value={name} onChange={setName} />
        <TextInput label="命令路径" value={executablePath} placeholder="留空使用 PATH" onChange={setExecutablePath} />
        <TextInput label="API 地址" value={baseUrl} placeholder="https://..." onChange={setBaseUrl} />
        <TextInput label="模型" value={model} placeholder="模型 ID" onChange={setModel} />
        <SettingsSelect label="权限模式" value={permissionMode} options={permissionModeOptions} onChange={setPermissionMode} />
        <SettingsSelect label="推理强度" value={reasoningEffort} options={reasoningEffortOptions} onChange={setReasoningEffort} />
        <TextInput label="工作目录" value={workingDirectory} placeholder="可选" onChange={setWorkingDirectory} />
        {profile.kind === "claude" ? (
          <TextInput label="配置路径" value={configPath} placeholder="可选" onChange={setConfigPath} />
        ) : (
          <SettingsSelect label="wire_api（暂未接入）" value={wireApi} options={wireApiOptions} onChange={setWireApi} disabled />
        )}
      </div>

      {profile.kind === "codex" ? (
        <div className="settings-panel">
          <div className="toggle-header">
            <div>
              <h3>Codex app-server</h3>
              <p>Windows 当前固定通过 stdio 启动 Codex app-server；Host/Port 监听模式暂未接入。</p>
            </div>
            <label className="switch">
              <input checked={appServerEnabled} disabled type="checkbox" onChange={(event) => setAppServerEnabled(event.currentTarget.checked)} />
              <span />
            </label>
          </div>
          <div className="settings-grid">
            <TextInput label="Host（暂未接入）" value={appServerHost} onChange={setAppServerHost} disabled />
            <TextInput label="Port（暂未接入）" value={appServerPort} placeholder="可选" onChange={setAppServerPort} disabled />
          </div>
        </div>
      ) : null}

      <div className="settings-grid">
        {profile.kind === "claude" ? (
          <SecretEditor profile={profile} field="authToken" label="ANTHROPIC_AUTH_TOKEN" />
        ) : (
          <SecretEditor profile={profile} field="apiKey" label="OPENAI_API_KEY" />
        )}
        <SettingsPanel title="当前状态" subtitle="只显示配置摘要和 secret 引用，不显示密钥明文。">
          <div className="settings-row"><span>启用</span><b>{profile.enabled ? "是" : "否"}</b></div>
          <div className="settings-row"><span>Secret</span><b>{secretSummary(profile)}</b></div>
        </SettingsPanel>
      </div>

      <div className="settings-actions">
        <button type="button" onClick={() => void deleteProfile(profile.id)}>
          <Trash2 size={14} /> 删除
        </button>
        <span />
        <button type="button" onClick={() => void setDefaultProfile(profile.id)} disabled={profile.isDefault}>
          {profile.isDefault ? "当前" : "设为当前"}
        </button>
        <button className="settings-primary-button" type="button" onClick={saveProfile}>
          <Save size={14} /> 保存
        </button>
      </div>
    </div>
  );
}

function SecretEditor({ field, label, profile }: { field: SecretField; label: string; profile: CLIProfile }) {
  const setProfileSecret = useSettingsStore((state) => state.setProfileSecret);
  const clearProfileSecret = useSettingsStore((state) => state.clearProfileSecret);
  const [secretValue, setSecretValue] = useState("");
  const ref = profile.secretRefs[field];

  function saveSecret() {
    const value = secretValue.trim();
    if (!value) {
      return;
    }
    void setProfileSecret(profile.id, field, value).then(() => setSecretValue(""));
  }

  return (
    <SettingsPanel title={label} subtitle={ref ? `已保存引用：${ref.label}` : "未保存密钥。明文只提交到 main 进程。"}>
      <input
        className="settings-input"
        type="password"
        value={secretValue}
        placeholder={ref ? "输入新值以替换" : "输入后保存到 safeStorage"}
        onChange={(event) => setSecretValue(event.currentTarget.value)}
      />
      <div className="settings-actions">
        <button type="button" disabled={!ref} onClick={() => void clearProfileSecret(profile.id, field)}>清除</button>
        <button className="settings-primary-button" type="button" disabled={!secretValue.trim()} onClick={saveSecret}>保存密钥</button>
      </div>
    </SettingsPanel>
  );
}

function RemoteChatSettings() {
  return (
    <div className="settings-stack">
      <div className="settings-card remote-chat-card">
        <WindowsHostPanel />
      </div>
    </div>
  );
}

function WindowsHostPanel() {
  const [status, setStatus] = useState<RemoteHostStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const bridgeAvailable = Boolean(window.codevoke?.remoteHost);

  useEffect(() => {
    const bridge = window.codevoke?.remoteHost;
    if (!bridge) {
      return;
    }
    let active = true;
    void bridge.getStatus().then((value) => {
      if (active) setStatus(value);
    }).catch(() => undefined);
    const unsubscribe = bridge.onStatus((value) => {
      if (active) setStatus(value);
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);

  async function runHostAction(action: () => Promise<RemoteHostStatus>, successMessage?: string) {
    const bridge = window.codevoke?.remoteHost;
    if (!bridge) {
      return;
    }
    setBusy(true);
    setMessage(null);
    try {
      const next = await action();
      setStatus(next);
      if (successMessage) setMessage(successMessage);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "操作失败，请重试。");
    } finally {
      setBusy(false);
    }
  }

  async function copyText(text: string, successMessage: string) {
    try {
      await navigator.clipboard.writeText(text);
      setMessage(successMessage);
    } catch {
      setMessage("复制失败，请手动选择文本。");
    }
  }

  const enabled = status?.enabled ?? false;
  const running = status?.running ?? false;
  const serviceLabel = running ? "运行中" : enabled ? "启动中" : "已停止";

  return (
    <section className="remote-service-panel settings-panel">
      <div className="toggle-header">
        <div>
          <h3>手机连接本机（局域网直连）</h3>
          <p>开启后，手机在同一 Wi-Fi 下即可直连这台 Windows，发送消息并实时查看输出，无需口令。</p>
        </div>
        <label className="switch">
          <input
            checked={enabled}
            disabled={busy || !bridgeAvailable}
            type="checkbox"
            onChange={(event) => void runHostAction(() => window.codevoke!.remoteHost.setEnabled(event.currentTarget.checked))}
          />
          <span />
        </label>
      </div>

      <div className="remote-metric-chips">
        <MetricChip title="服务状态" value={serviceLabel} />
        <MetricChip title="局域网地址" value={status?.lanAddress ?? "未发布"} />
        <MetricChip title="当前连接" value={`${status?.activeConnectionCount ?? 0} 台`} />
      </div>

      {enabled ? (
        <div className="settings-grid">
          <SettingsPanel title="局域网地址" subtitle="手机与本机处于同一 Wi-Fi 时，使用以下地址连接。">
            <div className="settings-row"><span>地址</span><code>{status?.lanAddress ?? "等待网络…"}</code></div>
            <div className="settings-row"><span>端口</span><b>{status?.port ?? "-"}</b></div>
            {status?.lanAddress ? (
              <div className="settings-actions">
                <button type="button" onClick={() => void copyText(status.lanAddress as string, "局域网地址已复制。")}>
                  <Copy size={14} /> 复制地址
                </button>
              </div>
            ) : null}
          </SettingsPanel>
        </div>
      ) : null}

      {status?.lastError ? <p className="account-message error">{status.lastError}</p> : null}
      {message ? <p className="settings-hint">{message}</p> : null}
      {!bridgeAvailable ? <p className="settings-hint">远程 host 接口不可用。</p> : null}
    </section>
  );
}

function MetricChip({ title, value }: { title: string; value: string }) {
  return (
    <div className="remote-metric-chip">
      <span>{title}</span>
      <b>{value}</b>
    </div>
  );
}

function AppendRulesSettings({ settings }: { settings: AppSettings }) {
  const savePatch = useSettingsStore((state) => state.savePatch);
  const [appendRule, setAppendRule] = useState(settings.appendRule.content);

  useEffect(() => {
    setAppendRule(settings.appendRule.content);
  }, [settings.appendRule.content]);

  return (
    <div className="settings-stack">
      <div className="settings-card">
        <div className="toggle-header">
          <div>
            <h3>发送时追加到实际 prompt</h3>
            <p>聊天气泡仍显示原始输入，追加内容会随请求一起发送给当前 CLI。</p>
          </div>
          <label className="switch">
            <input
              checked={settings.appendRule.enabled}
              type="checkbox"
              onChange={(event) => void savePatch({ appendRule: { ...settings.appendRule, enabled: event.currentTarget.checked } })}
            />
            <span />
          </label>
        </div>
        <textarea className="settings-textarea compact" value={appendRule} onChange={(event) => setAppendRule(event.currentTarget.value)} />
        <div className="settings-actions">
          <button type="button" onClick={() => setAppendRule("")}>清空</button>
          <button className="settings-primary-button" type="button" onClick={() => void savePatch({ appendRule: { ...settings.appendRule, content: appendRule } })}>
            <Save size={14} /> 保存
          </button>
        </div>
      </div>
    </div>
  );
}

function GlobalRulesSettings({ settings }: { settings: AppSettings }) {
  const savePatch = useSettingsStore((state) => state.savePatch);
  const [target, setTarget] = useState<GlobalRuleTarget>("claude");
  const currentRule = settings.globalRules[target];
  const [ruleText, setRuleText] = useState(currentRule.content);

  useEffect(() => {
    setRuleText(currentRule.content);
  }, [currentRule.content, target]);

  return (
    <div className="settings-stack">
      <div className="settings-card">
        <div className="segmented" role="tablist" aria-label="规则目标">
          {(["claude", "codex"] as const).map((item) => (
            <button className={target === item ? "active" : ""} key={item} type="button" onClick={() => setTarget(item)}>
              {item === "claude" ? "Claude Code" : "Codex"}
            </button>
          ))}
        </div>
        <div className="rule-path">
          <span>文件路径</span>
          <code>{currentRule.path || (target === "claude" ? "~/.claude/CLAUDE.md" : "~/.codex/AGENTS.md")}</code>
        </div>
        <textarea className="settings-textarea compact" value={ruleText} onChange={(event) => setRuleText(event.currentTarget.value)} />
        <div className="settings-actions">
          <button type="button" onClick={() => setRuleText(currentRule.content)}>重新读取</button>
          <button
            className="settings-primary-button"
            type="button"
            onClick={() => void savePatch({
              globalRules: {
                ...settings.globalRules,
                [target]: {
                  ...currentRule,
                  content: ruleText
                }
              }
            })}
          >
            <Save size={14} /> 保存
          </button>
        </div>
        <p className="hint">保存到主设置服务；同步到 CLI 实际规则文件需要主线补文件写入服务。</p>
      </div>
    </div>
  );
}

function AboutSettings() {
  const appInfo = useSettingsStore((state) => state.appInfo);
  const loadAppInfo = useSettingsStore((state) => state.loadAppInfo);

  useEffect(() => {
    if (!appInfo) {
      void loadAppInfo();
    }
  }, [appInfo, loadAppInfo]);

  return (
    <div className="settings-stack">
      <div className="settings-card">
        <div className="about-hero">
          <div className="about-logo"><AppLogo /></div>
          <div>
            <h3>Codevoke</h3>
            <p>一个轻量级的 Claude Code / Codex 桌面客户端</p>
          </div>
        </div>
      </div>
      <div className="settings-card">
        <div className="settings-row"><span>当前版本</span><b>{appInfo?.version ?? "读取中"}</b></div>
        <div className="settings-row"><span>平台</span><b>{appInfo ? `${appInfo.platform} / ${appInfo.arch}` : "读取中"}</b></div>
      </div>
    </div>
  );
}

function SettingsPanel({ children, subtitle, title }: { children: React.ReactNode; subtitle: string; title: string }) {
  return (
    <div className="settings-panel">
      <h3>{title}</h3>
      <p>{subtitle}</p>
      {children}
    </div>
  );
}

function TextInput({
  disabled,
  label,
  onChange,
  placeholder,
  value
}: {
  disabled?: boolean;
  label: string;
  onChange: (value: string) => void;
  placeholder?: string;
  value: string;
}) {
  return (
    <label>
      <span className="settings-label">{label}</span>
      <input className="settings-input" disabled={disabled} value={value} placeholder={placeholder} onChange={(event) => onChange(event.currentTarget.value)} />
    </label>
  );
}

function SettingsSelect<T extends string>({
  disabled,
  label,
  onChange,
  options,
  value
}: {
  disabled?: boolean;
  label: string;
  onChange: (value: T) => void;
  options: Array<{ value: T; label: string }>;
  value: T;
}) {
  return (
    <label>
      <span className="settings-label">{label}</span>
      <select className="settings-input" disabled={disabled} value={value} onChange={(event) => onChange(event.currentTarget.value as T)}>
        {options.map((option) => (
          <option key={option.value} value={option.value}>{option.label}</option>
        ))}
      </select>
    </label>
  );
}

function secretSummary(profile: CLIProfile): string {
  const labels = [
    profile.secretRefs.apiKey ? "apiKey" : null,
    profile.secretRefs.authToken ? "authToken" : null
  ].filter(Boolean);
  return labels.length > 0 ? labels.join(" / ") : "未配置";
}

function emptyToUndefined(value: string): string | undefined {
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function firstLine(value: string | null): string | null {
  return value?.split(/\r?\n/).map((line) => line.trim()).find(Boolean) ?? null;
}
