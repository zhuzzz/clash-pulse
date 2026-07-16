# clash-refresh-node

Triggers a Clash **Delay check**, filters nodes by a name keyword, and switches to the **lowest-latency matching node**. It is the scripted equivalent of clicking the dashboard's delay-check button and then choosing the fastest node by hand.

It drives the Clash / mihomo [external-controller REST API](https://en.clash.wiki/runtime/external-controller.html) directly (the same API the web dashboard uses), so it works headlessly and doesn't depend on the dashboard UI.

## How it works

1. `GET /proxies` — read the group and its member nodes.
2. **Delay check** the candidates:
   - mihomo: `GET /group/:name/delay` (tests the whole group at once), or
   - Clash Premium fallback: `GET /proxies/:name/delay` per node, in parallel.
3. Filter members by name (default `日本|JP|Japan`), rank by latency.
4. `PUT /proxies/:group {"name": "<fastest>"}` — switch the Selector to the winner.

## Setup

Requires Node.js ≥ 18 (uses the built-in `fetch`). No dependencies.

Create a private local configuration first:

```bash
cp config.example.json config.json
```

Then edit `config.json`:

```json
{
  "controller": "http://127.0.0.1:9090",
  "secret": "",
  "group": "Proxy",
  "filter": "日本|JP|Japan",
  "exclude": "",
  "testUrl": "http://www.gstatic.com/generate_204",
  "timeout": 5000,
  "maxDelay": 0,
  "watchInterval": 300,
  "allowInsecureRemote": false
}
```

- `controller` / `secret` — your external-controller address and API secret. Find them in your Clash config under `external-controller` / `secret`.
- `group` — the Selector group to control (your dashboard shows `Proxy`).
- `filter` — regex for node names to consider. `exclude` removes matches (e.g. exclude test nodes with `TEST`).
- `maxDelay` — if > 0, ignore nodes slower than this (ms).
- `config.json` is ignored by Git because it may contain a Controller secret. Only commit `config.example.json`.
- Remote Controllers must use HTTPS. `allowInsecureRemote` is an explicit opt-out for trusted private networks; it sends the Bearer secret without transport encryption.

## Usage

```bash
node index.js              # run once
node index.js --dry-run    # report the fastest node without switching
node index.js --watch      # keep refreshing every watchInterval seconds
node index.js --group Proxy --keyword "日本"               # literal keyword
node index.js --group Proxy --filter "日本|JP" --exclude TEST # regular expressions
```

Config precedence: `config.json` < env (`CLASH_CONTROLLER`, `CLASH_SECRET`, `CLASH_GROUP`, `CLASH_FILTER`) < CLI flags. Avoid passing secrets as CLI arguments because they can be saved in shell history and exposed in the process list.

## macOS 一键触发

首次使用先编辑 `config.json`，确认 Clash/Mihomo 已开启 `external-controller`，然后测试：

```bash
npm test
node index.js --dry-run
```

有两种一键方式：

1. **直接双击**：在 Finder 中双击 `macos/clash-refresh.command`，执行一次全量测速和切换。
2. **安装为菜单栏 App**：运行下面的命令，之后右上角会常驻显示当前节点延迟：

```bash
chmod +x macos/*.sh macos/*.command
./macos/install-app.sh
```

菜单栏延迟每 10 秒采样一次，只测试当前节点，不会自动切换。点击延迟可查看当前节点和上次检测时间，并可选择“立即重新检测”或“检测全部并切换最快节点”。

要设置全局快捷键：打开 macOS「快捷指令」→ 新建快捷指令 → 添加“打开 App”动作 → 选择 **Clash Fastest Node** → 在详情中勾选“用作快速操作”并设置键盘快捷键。App 已经运行时，再次打开会执行全量测速并切换最快节点。

安装时会把当前 `config.json` 以仅当前用户可读的权限复制进 App。修改配置后请重新执行 `./macos/install-app.sh`，然后退出并重开 App。

日志保存在 `$TMPDIR/clash-refresh-node.log`。如果 Clash 的 Controller 使用了密钥，请只把它写在本机 `config.json` 中；该文件已被 `.gitignore` 排除。

## Run it on a schedule

`--watch` keeps the process alive and re-selects the fastest Japan node on an interval. Or wire `node index.js` into cron / launchd for a periodic refresh.
