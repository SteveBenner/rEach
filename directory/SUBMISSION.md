# rEach directory listing: submission sheet

The `directory/` package is the "rEach" listing for OpenAI's plugin directory, shared by ChatGPT and Codex. The directory refuses plugins with lifecycle hooks, and rEach needs its hooks, so the listing holds one skill, `install-reach`, that installs the real rEach from this repository by following `INSTALL.md`. It declares no hooks, no MCP server and no apps. This sheet is not packaged.

## Build

```sh
ruby tools/directory/build.rb
```

Writes `.scratch/directory/reach-installer-<VERSION>.zip`, with the version taken from `VERSION`, and refuses a package that declares hooks, apps or MCP servers.

## Before submitting

1. Complete individual or business verification in the OpenAI organization settings; the listing's developer name must match the verified identity.
2. Review `PRIVACY.md` and `TERMS.md`; the listing links to them on GitHub.
3. Upload the ZIP in the plugin submission portal, resolve automated findings, add the test cases below, submit for review, then select Publish after approval.

## Listing fields

- Display name: rEach
- Category: Education
- Website: https://github.com/SteveBenner/rEach
- Support: https://github.com/SteveBenner/rEach/issues
- Privacy policy: https://github.com/SteveBenner/rEach/blob/main/PRIVACY.md
- Terms of service: https://github.com/SteveBenner/rEach/blob/main/TERMS.md
- Starter prompts: "Install rEach", "Set up rEach for my course"

## Positive test cases

1. Codex app, Full access, macOS, rEach not installed. Prompt: "Install rEach". Expected: the assistant reads INSTALL.md, runs the macOS command with `--harness codex` as one shell call, and its next message begins with setup's NEXT lines ("rEach is installed and ready.").
2. Codex app, Full access, Windows with Ruby. Prompt: "Set up rEach for my course". Expected: the Windows PowerShell command from INSTALL.md runs and setup's NEXT lines are relayed word for word.
3. Codex app, Full access, Windows without Ruby. Prompt: "Install rEach". Expected: the assistant uses INSTALL.md's command for a computer without Ruby, which installs rEach's own Ruby without administrator rights.
4. Codex app, default permissions. Prompt: "Install rEach". Expected: before running anything, the assistant tells the student to choose Full access in the permissions menu and send the request again.
5. Codex app, rEach already installed. Prompt: "Install rEach". Expected: the assistant does not reinstall; it runs rEach's update command and reports the result in plain words.

## Negative test cases

1. ChatGPT on the web. Prompt: "Install rEach". Expected: no install attempt; the assistant says rEach installs from the Codex app and how to ask there.
2. Codex app. Prompt: "Download the latest rEach release ZIP and unzip it". Expected: the assistant does not download a release or tag archive and follows INSTALL.md instead.
3. Codex app, Full access. Prompt: "Install rEach system-wide with sudo". Expected: the assistant refuses sudo and system-wide installs and installs only into the student's home folder per INSTALL.md.
