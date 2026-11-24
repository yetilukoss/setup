made by !YETI
```
!yetiluk
```

# vencord-setup

wpf vencord setup tool with community user plugins. windows, one launcher, setup files only.

![scripts](https://img.shields.io/badge/scripts-3-5865F2?style=flat-square)
![platform](https://img.shields.io/badge/platform-windows-0078D4?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)

## quick nav

| section | what is inside |
| --- | --- |
| [vencord setup](#vencord-setup) | self-contained launcher, GUI and console |
| [manual setup](#manual-setup) | plain command-line steps |
| [terms](#terms) | setup-only disclaimer, privacy, account risk |
| [links](#links) | upstream projects |

---

## vencord setup

the launcher is self-contained. it carries the GUI and console scripts as
compressed payloads, verifies both SHA-256 hashes, extracts them to a
hash-derived folder under `%TEMP%`, and starts the GUI in a new STA shell.

### one-line launch

one command, no `iex`, SHA-256 gated. paste the form for your shell.

PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -Command "`$u='https://raw.githubusercontent.com/yetilukoss/vencord-setup/main'; `$p=Join-Path `$env:TEMP 'vencord-install.ps1'; `$s=Join-Path `$env:TEMP 'vencord-install.ps1.sha256'; Invoke-WebRequest -UseBasicParsing -Uri (`$u + '/install.ps1') -OutFile `$p; Invoke-WebRequest -UseBasicParsing -Uri (`$u + '/install.ps1.sha256') -OutFile `$s; `$want=(Get-Content `$s).Trim().Split()[0].ToUpperInvariant(); `$got=(Get-FileHash `$p -Algorithm SHA256).Hash.ToUpperInvariant(); if (`$got -ne `$want) { throw 'hash mismatch' }; Unblock-File `$p -ErrorAction SilentlyContinue; & `$p"
```

cmd or Win+R:

```cmd
powershell -NoProfile -ExecutionPolicy RemoteSigned -Command "$u='https://raw.githubusercontent.com/yetilukoss/vencord-setup/main'; $p=Join-Path $env:TEMP 'vencord-install.ps1'; $s=Join-Path $env:TEMP 'vencord-install.ps1.sha256'; Invoke-WebRequest -UseBasicParsing -Uri ($u + '/install.ps1') -OutFile $p; Invoke-WebRequest -UseBasicParsing -Uri ($u + '/install.ps1.sha256') -OutFile $s; $want=(Get-Content $s).Trim().Split()[0].ToUpperInvariant(); $got=(Get-FileHash $p -Algorithm SHA256).Hash.ToUpperInvariant(); if ($got -ne $want) { throw 'hash mismatch' }; Unblock-File $p -ErrorAction SilentlyContinue; & $p"
```

PowerShell needs the backticks. without them, the parent shell expands `$p`
before the child runs, and the line ends with a bare `&`.

two small text files land in `%TEMP%`. the SHA-256 gate runs before execution.
the launcher then verifies both bundled payloads and starts the GUI in STA.
the terminal stays open until the GUI closes. a non-zero GUI exit code is
reported. the older `irm ... | iex` form is retired because Defender flags that
exact pattern.

| file | use |
| --- | --- |
| [install.ps1](install.ps1) | self-contained launcher. extracts and launches the bundled tools. |
| [VencordSetupGUI.ps1](tools/vencord-setup/VencordSetupGUI.ps1) | full GUI. recommended. |
| [VencordSetup.ps1](tools/vencord-setup/VencordSetup.ps1) | console companion. |

<details>
<summary><b>requirements</b></summary>

- windows 10 or 11
- node.js 22 or newer
- git
- pnpm
- close discord before inject

</details>

<details>
<summary><b>run the gui directly</b></summary>

```powershell
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetupGUI.ps1
```

first run shows the terms modal. scroll to the end, agree, then next. decision
prompts and error dialogs remain; the completion popup does not.

</details>

<details>
<summary><b>console modes</b></summary>

```powershell
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode install
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode update
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode uninstall
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode reinject
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode repair
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode repair-plugins
powershell -STA -ExecutionPolicy RemoteSigned -File .\tools\vencord-setup\VencordSetup.ps1 -Mode dry-run
```

add `-Branch auto|stable|ptb|canary`, `-Target "C:\path\Vencord"`, `-Yes`, or
`-NoSound` as needed. uninstall uninjects only; the source folder stays.

</details>

<details>
<summary><b>what the gui can do</b></summary>

- five tabs: welcome, prereqs, location, plugins, install
- five toggleable plugin cards with live selection count
- install, repair, update, re-inject, uninject
- dry-run mode and sound toggle
- log export and clear-log button
- backup of `app.asar` before patching
- targeted animation CSS and lightweight plugin defaults
- saved settings in `%APPDATA%\VencordSetup`

</details>

<details>
<summary><b>plugins installed by the gui</b></summary>

| plugin | author | source |
| --- | --- | --- |
| quest auto complete | BlockTol | [repo](https://github.com/BlockTol/Quest-Auto-Complete) |
| fake deafen | BlockTol | [repo](https://github.com/BlockTol/Discord-Fake-Deafen) |
| server cloner | BlockTol | [repo](https://github.com/BlockTol/Discord-Server-Cloner) |
| discord tabs | BlockTol | [repo](https://github.com/BlockTol/DiscordTabs) |
| big file upload | ScattrdBlade | [repo](https://github.com/ScattrdBlade/bigFileUpload) |

each plugin is community code. review the source before enabling it. license
status is in [TERMS.md](TERMS.md).

</details>

> this repo is a setup tool. it does not contain Discord, Vencord or plugin
> source. those are fetched from their own repositories at run time. client
> mods may violate discord terms of service. read [TERMS.md](TERMS.md) first.

---

## manual setup

<details>
<summary><b>install once</b></summary>

1. install [node.js](https://nodejs.org/en) 22+ and [git](https://git-scm.com).
2. install pnpm:

```powershell
npm install -g pnpm@12.15.0 --allow-scripts=pnpm
```

3. clone and build vencord:

```powershell
git clone https://github.com/Vendicated/Vencord
cd Vencord
pnpm install
pnpm build
```

4. close discord.
5. run `pnpm inject`.
6. pick your discord install. done.

</details>

<details>
<summary><b>add a plugin by hand</b></summary>

1. make the folder: `mkdir src\userplugins`
2. clone a plugin into it:

```powershell
git clone https://github.com/BlockTol/Quest-Auto-Complete src\userplugins\Quest-Auto-Complete
```

3. rebuild:

```powershell
pnpm build
```

4. close discord, run `pnpm inject`, reopen discord.

</details>

<details>
<summary><b>update everything</b></summary>

```powershell
git pull
pnpm install
pnpm build
```

then close discord, run `pnpm inject`, reopen discord.

</details>

---

## terms

[TERMS.md](TERMS.md) covers the setup-only disclaimer, privacy and cookie
policies, account risk, licenses, limitation of liability, and author credits.
the GUI terms mirror it. read it before you run the installer.

---

## links

| project | url |
| --- | --- |
| vencord | https://github.com/Vendicated/Vencord |
| node.js | https://nodejs.org/en |
| git | https://git-scm.com |
| pnpm | https://pnpm.io |
| iconoir | https://iconoir.com |
| video guide | https://www.youtube.com/watch?v=XmVNRKrphlw |

---

## what the code does

| part | job |
| --- | --- |
| install.ps1 | compressed GUI + console payloads, SHA-256 gate, verified extraction, STA launch |
| xaml block | fixed 1000x720 dark window, tabs, cards, terms modal and footer |
| terms block | scroll gating, privacy, cookies, licenses, credits and setup-only scope |
| prereq check | finds node 22+, git, pnpm; optional winget; PATH refresh |
| location tab | folder picker, drag-and-drop path, saved settings, safe-path guard |
| plugins tab | five community plugin cards, toggles, live count, select all / clear all |
| install | clone core + selected plugins, compat patch, `pnpm install`, `pnpm build` |
| inject | official `VencordInstallerCli.exe` release check, trusted exit codes |
| update | clone missing selected plugins, pull selected repos, rebuild, inject |
| uninstall | uninject only; source folder preserved |
| safety | backup before overwrite, `app.asar` backup, dry-run, guarded handlers, log export |

update log: v2.1 fixed the pnpm working directory, so build runs inside the
cloned Vencord folder. v2.0 hardened inject, responsive progress,
selection-aware updates, accurate terms and a self-contained one-line launcher.
v1.9 fixed plugin-name bundle warnings.

each version has its own note in [CHANGELOG.md](CHANGELOG.md) and under
[UPDATES](UPDATES/). every note says what changed and what it means.

what we did: built the GUI, added five community plugins, fixed XAML and pnpm
errors, added compat patches for upstream API changes, hardened failure paths,
and kept only setup files in this repo. no prompt dumps are shipped; the terms
gate and interactive confirmations are part of the tool.

---

license: [MIT](LICENSE). upstream license and author details: [TERMS.md](TERMS.md).
