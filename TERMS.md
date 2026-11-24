made by !YETI
```
!yetiluk
```

# terms, privacy, cookie policy & setup-only disclaimer

last updated: 2026-11-22

this document is a template, not legal advice. have a qualified attorney review
it for your jurisdiction. no set of terms guarantees immunity from lawsuits.
the GUI shows the same terms before setup starts.

---

## the short version

this repository is a **setup tool**. it installs and configures software that
other people wrote. it is not a Discord client modification, and it is not a
Vencord or plugin source repository.

using a modified Discord client **violates Discord's Terms of Service**. saying
"this is only a setup" does not change that. Discord applies its rules to the
client you run, not to who wrote the installer. this disclaimer limits the
authors' liability. it is not permission from Discord, and it will not stop
Discord from enforcing its rules.

enforcement can include account bans. if your account matters to you, do not
use client mods.

---

## 1. what this tool does

- checks that Node.js 22+, Git and pnpm are installed
- clones `Vendicated/Vencord` into a folder you choose
- clones selected user plugins from their own repositories
- runs `pnpm install` and `pnpm build`
- checks the official `VencordInstallerCli.exe` release through Vencord's
  installer helper and runs it against a local Discord install
- supports branch choices `auto`, `stable`, `ptb` and `canary`
- if launched from the one-line command, fetches only `install.ps1` from
  `raw.githubusercontent.com`; the GUI and console are bundled inside it

no services, scheduled tasks, or persistent background agents are installed.
beeps are short-lived. a one-shot `git fetch origin` update check runs on launch
when a saved target with a `.git` folder exists. no registry changes are made
beyond what Discord, pnpm, or optional winget installs make themselves.

---

## 2. warning - account risk

client modifications violate Discord's Terms of Service. enforcement can
include account bans. your account is at risk. if your account is critical to
you, do not proceed. you accept all risk.

stating that this repo is only a setup tool does not change Discord's rules.
Discord applies its Terms to the client you run, not to who wrote the installer.
this disclaimer limits our liability. it does not grant permission from Discord
or prevent enforcement by Discord.

---

## 3. third-party code

plugins are authored by others (BlockTol, ScattrdBlade). review their source
before enabling them. we are not responsible for plugin behavior.

DiscordTabs reads account tokens from Discord's own local store to log a new
tab in. the token is passed inside Discord and is not written to a file or sent
to a server by that plugin. enable it only if you accept that access.
DiscordTabs also checks `api.github.com` for its own releases at runtime.

bigFileUpload sends files you choose to external hosting providers.

---

## 4. no redistribution

do not redistribute patched Discord binaries.

---

## 5. licenses

this setup code is MIT. Vencord is GPL-3.0. DiscordTabs declares
GPL-3.0-or-later in its source headers and has no LICENSE file. other plugins
have no license file in their repositories. review each repo before use.

"not stated in repository" means no license file exists there. all rights stay
with that author unless they say otherwise. do not assume reuse permission.

---

## 6. privacy policy

- scope: the tool runs entirely on your local machine
- data we collect: none. no telemetry, analytics, crash reports, usage metrics
  or tracking. we have no servers
- network requests:
  0. one-line launch only: fetch `install.ps1` and `install.ps1.sha256` from
     `raw.githubusercontent.com` (the GUI and console are bundled; no second
     download)
  1. `git clone` of Vencord and the selected plugin repositories
  2. `pnpm install` to the npm registry
  3. optional winget install of missing prerequisites, only if you request it
  4. one-shot `git fetch origin` on GUI launch, only when a saved target with
     a `.git` folder exists
  5. official `VencordInstallerCli.exe` release check on each inject
  6. DiscordTabs release check to `api.github.com` at runtime
  7. local patching only, no network
- stored locally: the folder you pick, Discord's own config, pnpm/npm cache
- third parties: Discord and GitHub log their own requests under their policies
- Vencord settings sync is optional, off by default, and handled by Vencord
- rights: delete the created folder to remove local setup data. no account,
  no registration, no retention by us

---

## 7. cookie policy

- this tool sets zero cookies, zero localStorage, zero sessionStorage and zero
  tracking identifiers
- the Discord client may set its own session cookies. we do not read, modify or
  transmit them
- Vencord may store plugin settings in Discord's local storage
- no advertising, analytics or cross-site cookies
- no cookie banner is shown because none are set by us

---

## 8. terms of use

1. as-is: no warranty, no guarantee of fitness for purpose.
2. account risk: client mods violate Discord ToS. you accept all risk to your
   Discord account, including bans.
3. third-party code: plugins authored by others. review source. we are not
   responsible.
4. no redistribution of patched Discord binaries.
5. licenses: setup code MIT; Vencord GPL-3.0; DiscordTabs source headers
   declare GPL-3.0-or-later; other plugins: no license file in their repos.
6. no malicious use: do not use to harm others or violate laws or terms.
7. age: you must be old enough to use Discord in your region.
8. acceptance: continuing means you read and accept all terms, warnings,
   privacy policy and cookie policy above.

---

## 9. assets

- sounds: bencho.dev names mapped to synthesized tones. no audio files shipped
- icons: iconoir.com outline icons converted to WPF path data, MIT licensed
- Segoe Fluent Icons: Windows built-in fallback glyphs
- no copyrighted audio or icon assets are shipped by this repository

---

## 10. no affiliation

not affiliated with, endorsed by or sponsored by Discord Inc., Vencord, or any
plugin author. "Discord" is a trademark of Discord Inc.

---

## 11. acceptable use policy

you agree not to use this tool to:

- violate any law, regulation or third-party terms, including Discord's
- harm, harass, defraud or exploit anyone
- distribute malware, spam or abusive content
- bypass security controls of systems you do not own
- use it in a way that could damage our reputation or expose us to liability

violation may end your access to future updates.

---

## 12. license grant

the setup code in this repository is licensed under the MIT License. MIT permits
use, copying, modification, merging, publication, distribution, sublicensing,
and sale, provided the copyright notice and permission notice are included in
copies or substantial portions. third-party projects keep their own licenses.
Vencord is GPL-3.0 and DiscordTabs declares GPL-3.0-or-later in its source
headers.

---

## 13. limitation of liability

to the maximum extent permitted by law, the authors are not liable for
indirect, incidental, special, consequential or punitive damages, including
loss of account, loss of data, loss of profits, or service interruption. total
liability is limited to the amount you paid for this tool, which is zero. some
jurisdictions do not allow these limits, so they apply only to the extent
permitted.

---

## 14. indemnification

you agree to hold the authors harmless from claims, losses, damages,
liabilities and expenses, including legal fees, arising from your use of this
tool or your violation of these terms or third-party rights.

---

## 15. disclaimer of warranties

the tool is provided "as is" and "as available", without warranty of any kind,
express or implied, including merchantability, fitness for a particular purpose,
title and non-infringement. we do not warrant it is error-free, uninterrupted,
secure, or compatible with future Discord updates.

---

## 16. termination of updates

the MIT license for the setup code is perpetual for copies already distributed.
we may stop publishing updates or close distribution channels at any time. this
does not revoke rights already granted under the MIT License.

---

## 17. governing law & dispute resolution

these terms are governed by the law of the primary author's jurisdiction.
disputes should first be raised informally. if unresolved, they go to courts or
binding arbitration of that jurisdiction, as applicable. you waive a jury trial
and class participation to the extent permitted by law.

---

## 18. severability

if any provision is held invalid or unenforceable, the remaining provisions
continue in full force.

---

## 19. entire agreement

these terms, together with the privacy and cookie policies above, constitute
the entire agreement between you and us regarding this tool and supersede all
prior agreements.

---

## 20. no waiver

failure to enforce any provision does not waive our right to enforce it later.

---

## 21. changes to terms

we may update these terms at any time. continued use after changes constitutes
acceptance for future updates. changes do not revoke the MIT rights already
granted for distributed copies under section 12. the "last updated" date is
shown at the top.

---

## 22. credits & third-party assets

| project | author | source | license |
| --- | --- | --- | --- |
| Vencord | Vendicated | [repo](https://github.com/Vendicated/Vencord) | GPL-3.0 |
| Quest-Auto-Complete | BlockTol | [repo](https://github.com/BlockTol/Quest-Auto-Complete) | not stated in repository |
| Discord-Fake-Deafen | BlockTol | [repo](https://github.com/BlockTol/Discord-Fake-Deafen) | not stated in repository |
| Discord-Server-Cloner | BlockTol | [repo](https://github.com/BlockTol/Discord-Server-Cloner) | not stated in repository |
| DiscordTabs | BlockTol | [repo](https://github.com/BlockTol/DiscordTabs) | GPL-3.0-or-later in source headers; no LICENSE file |
| bigFileUpload | ScattrdBlade | [repo](https://github.com/ScattrdBlade/bigFileUpload) | not stated in repository |
| icons | Iconoir | [site](https://iconoir.com) | MIT |
| sounds | bencho.dev | [site](https://bencho.dev/sounds) | synthesized tones, no files shipped |
| fallback glyphs | Microsoft | Segoe Fluent Icons, Windows built-in | Windows license |

setup code: MIT, copyright (c) 2026 yetilukoss. Node.js, Git and pnpm keep
their own licenses.

---

## 23. setup-only disclaimer

the code in this repository is a setup and automation helper. Vencord and the
user plugins are third-party projects fetched from their own repositories at
run time. we make no claim to authorship, ownership, or endorsement of those
projects. the accurate description is: this repository installs and configures
existing tools faster. that statement is factual. it is not a defense to a
Terms of Service violation and should not be presented as one.

---

credits: Vendicated (Vencord), BlockTol (four plugins), ScattrdBlade
(bigFileUpload), Iconoir, bencho.dev, Microsoft. full license status is in
section 22. Discord is a trademark of Discord Inc.
