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
import QRCode from "qrcode";
import { chatCLIDisplayNames, chatCLIValues } from "@shared/chat";
import { cliLaunchEnvFor } from "@shared/settings";
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
import type { RemoteHostPairingInfo, RemoteHostStatus, WanDiagnostics, WanEndpoint } from "@shared/ipc";
import { AppLogo } from "../AppLogo";
import { selectProfiles, useSettingsStore } from "../../stores/settingsStore";

type SettingsTabID =
  | "general"
  | CLIKind
  | "remoteChat"
  | "appendRules"
  | "globalRules"
  | "about";

interface SettingsPageProps {
  onBack?: () => void;
}

const tabs = [
  { id: "general", title: "通用", icon: Settings },
  ...chatCLIValues.map((cli) => ({
    id: cli as SettingsTabID,
    title: chatCLIDisplayNames[cli],
    icon: cli === "codex" ? Cpu : Terminal
  })),
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
  if ((chatCLIValues as readonly string[]).includes(selectedTab)) {
    return <ProfileSettings kind={selectedTab as CLIKind} settings={settings} />;
  }
  switch (selectedTab) {
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
            options={chatCLIValues.map((cli) => ({ value: cli, label: chatCLIDisplayNames[cli] }))}
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
  const [newName, setNewName] = useState(`${chatCLIDisplayNames[kind]} 配置`);
  const displayName = chatCLIDisplayNames[kind];

  return (
    <div className="settings-stack">
      <div className="settings-card">
        <div className="settings-card-intro">
          <h3>{displayName} 中转站列表</h3>
          <p>
            {kind === "codex"
              ? "列表管理 base_url、模型、命令路径和 API Key 引用；wire_api/app-server 网络监听暂未接入，不会伪造生效状态。"
              : "列表管理 API 地址、模型、命令路径和密钥引用；明文只会提交给 main 进程保存。"}
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
          <p>还没有 {displayName} 配置。</p>
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
  const envNames = cliLaunchEnvFor(profile.kind);
  const displayName = chatCLIDisplayNames[profile.kind];
  // 只有映射了注入环境变量的 CLI 才显示密钥字段，不伪造生效状态。
  const secretField: SecretField | null =
    profile.kind === "claude" ? "authToken" : envNames.apiKeyEnv ? "apiKey" : null;
  const secretLabel =
    profile.kind === "claude" ? "ANTHROPIC_AUTH_TOKEN" : envNames.apiKeyEnv ?? "";
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
        <h3>{displayName} Profile</h3>
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
        ) : null}
        {profile.kind === "codex" ? (
          <SettingsSelect label="wire_api（暂未接入）" value={wireApi} options={wireApiOptions} onChange={setWireApi} disabled />
        ) : null}
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
        {secretField ? (
          <SecretEditor profile={profile} field={secretField} label={secretLabel} />
        ) : null}
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
  const [pairing, setPairing] = useState<RemoteHostPairingInfo | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
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

  const enabled = status?.enabled ?? false;
  const running = status?.running ?? false;

  useEffect(() => {
    const bridge = window.codevoke?.remoteHost;
    if (!bridge || !running) {
      setPairing(null);
      return;
    }
    let active = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const fetchPairing = () => {
      void bridge.getPairing().then((value) => {
        if (!active) return;
        setPairing(value);
        // 6 位码 5 分钟过期：到期后自动重取（ensurePairingCode 会换新码）。
        const expiresAtMs = value ? Date.parse(value.codeExpiresAt) : Number.NaN;
        if (Number.isFinite(expiresAtMs)) {
          const delay = Math.max(1_000, expiresAtMs - Date.now() + 500);
          timer = setTimeout(fetchPairing, delay);
        }
      }).catch(() => undefined);
    };
    fetchPairing();
    return () => {
      active = false;
      if (timer) clearTimeout(timer);
    };
  }, [running]);

  useEffect(() => {
    if (!pairing) {
      setQrDataUrl(null);
      return;
    }
    let active = true;
    QRCode.toDataURL(pairing.pairingUri, { margin: 1, width: 220 })
      .then((url) => {
        if (active) setQrDataUrl(url);
      })
      .catch(() => {
        if (active) setQrDataUrl(null);
      });
    return () => {
      active = false;
    };
  }, [pairing]);

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

  async function refreshEndpoints() {
    const bridge = window.codevoke?.remoteHost;
    if (!bridge) return;
    setRefreshing(true);
    setMessage(null);
    try {
      setStatus(await bridge.refreshEndpoints());
    } catch {
      setMessage("诊断刷新失败，请重试。");
    } finally {
      setRefreshing(false);
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

  const serviceLabel = running ? "运行中" : enabled ? "启动中" : "已停止";
  const wan = status?.wan ?? null;
  const devices = status?.pairedDevices ?? [];

  return (
    <section className="remote-service-panel settings-panel">
      <div className="toggle-header">
        <div>
          <h3>手机连接本机（局域网 + 跨网直连）</h3>
          <p>开启后走 wss 加密 + 配对 token 鉴权：同一 Wi-Fi 自动发现，跨网扫二维码或粘贴连接串配对。</p>
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
        <MetricChip title="已配对设备" value={`${devices.length} 台`} />
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

          <SettingsPanel title="扫码 / 连接串配对" subtitle="手机扫码或粘贴连接串即可完成跨网配对；同一局域网也可用下方 6 位码配对。">
            {pairing ? (
              <>
                {qrDataUrl ? (
                  <div className="settings-row pairing-qr-row">
                    <img className="pairing-qr" src={qrDataUrl} alt="配对二维码" />
                  </div>
                ) : null}
                <div className="settings-row"><span>6 位配对码</span><b>{pairing.code}</b></div>
                <div className="settings-row"><span>配对码有效期至</span><b>{formatTime(pairing.codeExpiresAt)}</b></div>
                <div className="settings-row"><span>证书指纹</span><code>{shortFingerprint(pairing.fingerprintHex)}</code></div>
                <textarea className="settings-textarea compact" readOnly value={pairing.pairingUri} rows={3} />
                <div className="settings-actions">
                  <button type="button" onClick={() => void copyText(pairing.pairingUri, "连接串已复制。")}>
                    <Copy size={14} /> 复制连接串
                  </button>
                </div>
                {wan && wan.endpoints.every((endpoint) => endpoint.kind === "lan") ? (
                  <p className="settings-hint">当前未发布任何跨网候选地址，扫码/连接串仅局域网可用；跨网请先解决下方诊断项。</p>
                ) : null}
              </>
            ) : (
              <p className="settings-hint">服务未在监听，无法生成配对信息。</p>
            )}
          </SettingsPanel>
        </div>
      ) : null}

      {enabled && devices.length > 0 ? (
        <SettingsPanel title="已配对设备" subtitle="吊销后该设备立即无法连接，需要重新配对。">
          {devices.map((device) => (
            <div className="settings-row" key={device.deviceId}>
              <span>{device.deviceName}{device.via === "qr" ? "（扫码）" : ""}</span>
              <b>{device.lastSeen ? `上次连接 ${formatTime(device.lastSeen)}` : "未连接过"}</b>
              <button
                type="button"
                disabled={busy}
                onClick={() => void runHostAction(() => window.codevoke!.remoteHost.revokeDevice(device.deviceId), "已吊销。")}
              >
                <Trash2 size={14} /> 吊销
              </button>
            </div>
          ))}
        </SettingsPanel>
      ) : null}

      {enabled ? (
        <SettingsPanel title="跨网直连诊断" subtitle="电脑对外发布的候选地址：全球 IPv6 优先，路由器映射 IPv4 其次，局域网地址垫底。">
          <div className="settings-row"><span>默认网关</span><b>{wan?.gatewayIPv4 ?? "未发现"}</b></div>
          <div className="settings-row"><span>外部 IPv4</span><b>{wan?.externalIPv4 ?? "未获取"}{wan?.cgnatIPv4 ? "（CGNAT）" : ""}</b></div>
          <div className="settings-row"><span>映射方式</span><b>{mappingMethodLabel(wan?.mappingMethod)}</b></div>
          {(wan?.endpoints ?? []).map((endpoint) => (
            <div className="settings-row" key={`${endpoint.a}:${endpoint.p}`}>
              <span>{endpointKindLabel(endpoint.kind)}</span>
              <code>{endpoint.a}:{endpoint.p}</code>
              <b>{endpoint.status === "ok" ? "直连可用" : "未验证"}</b>
            </div>
          ))}
          {(wan?.notes ?? []).map((note) => (
            <div className="settings-row" key={note}><span>{note}</span></div>
          ))}
          <p className="settings-hint">
            路由器不支持自动映射时，请在路由器手动把 TCP {status?.port ?? 18765} 转发到本机（{status?.lanAddress ?? "本机局域网地址"}），然后让手机重新扫码。
            两端都无 IPv6 且没有公网 IPv4 时无法直连。
          </p>
          <div className="settings-actions">
            <button type="button" disabled={refreshing} onClick={() => void refreshEndpoints()}>
              <RefreshCw size={14} /> {refreshing ? "刷新中…" : "刷新诊断"}
            </button>
          </div>
        </SettingsPanel>
      ) : null}

      {status?.lastError ? <p className="account-message error">{status.lastError}</p> : null}
      {message ? <p className="settings-hint">{message}</p> : null}
      {!bridgeAvailable ? <p className="settings-hint">远程 host 接口不可用。</p> : null}
    </section>
  );
}

function endpointKindLabel(kind: WanEndpoint["kind"]): string {
  if (kind === "ipv6") return "IPv6";
  if (kind === "ipv4-mapped") return "IPv4（映射）";
  return "局域网";
}

function mappingMethodLabel(method: WanDiagnostics["mappingMethod"] | undefined): string {
  if (method === "nat-pmp") return "NAT-PMP";
  if (method === "upnp") return "UPnP";
  return "无";
}

function shortFingerprint(fp: string): string {
  return fp.length > 16 ? `${fp.slice(0, 8)}…${fp.slice(-8)}` : fp;
}

function formatTime(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString();
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
              {chatCLIDisplayNames[item]}
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
            <h3>acode</h3>
            <p>一个轻量级的 Claude Code / Codex 桌面客户端</p>
          </div>
        </div>
      </div>
      <div className="settings-card">
        <div className="settings-row"><span>当前版本</span><b>{appInfo?.version ?? "读取中"}</b></div>
        <div className="settings-row"><span>平台</span><b>{appInfo ? `${appInfo.platform} / ${appInfo.arch}` : "读取中"}</b></div>
      </div>
      <div className="settings-card">
        <div className="settings-row"><span>版权</span><b>© 2026 crispvibe</b></div>
        <div className="settings-row"><span>许可</span><b>仅限个人非商业使用 · 禁止商用</b></div>
        <div className="settings-row"><span>协议</span><b>PolyForm Noncommercial 1.0.0</b></div>
        <div className="settings-row"><span>QQ 群</span><b>Code 开源技术交流群</b></div>
        <div className="settings-row"><span>仓库</span><b>github.com/crispvibe/Acode-Desktop</b></div>
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
