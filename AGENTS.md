
Target platform: iOS 17.3, jailbroken with [Dopamine RootHide 3](https://github.com/roothide/Dopamine-roothide).

Write README.md and comments in English, and always answer my questions in Chinese.

Write code according to the best long-term solution.

When developing a tweak, follow [docs/develop-tweaks.md](docs/develop-tweaks.md).

When releasing a tweak, follow [docs/release-tweaks.md](docs/release-tweaks.md).

No dynamic debugging unless I explicitly ask for it. Do not launch apps on the device, read device logs, or add runtime probes (such as code that dumps a class's methods) to find out how an app behaves. Approval to install a package covers that install only. When a class or method cannot be found, use static analysis (the decrypted binary, through dsh) or ask me.


## Sub Agent

For decompilation work, use dsh (the DeepSeek Harness CLI) as a sub agent to do the analysis. The main agent reviews the results.

- **Model**: V4.1 Flash (`deepseek-flash`). The `headless` profile is already configured.
- **Separate directories**: Each task gets its own directory, `/tmp/dsh-<task>/`, outside the repository. Parallel tasks use different directories. Copy reports worth keeping to `analysis/` (git-ignored) after review.
- **Task description**: Copy the binaries to analyze into the task directory and write a `TASK.md` there with the background, binary names, available tools, questions to answer, and output requirements. Require evidence for every conclusion (function names, addresses, key instructions) and a clear separation of fact from inference. The task directory is outside the repository, so dsh cannot read the conventions in this file. Put every convention it must follow in `TASK.md`, such as writing the report in Chinese and writing only to the current directory.
- **Running**: Run `dsh` inside the task directory. Run long tasks in the background.

  ```bash
  mkdir -p /tmp/dsh-<task> && cd /tmp/dsh-<task>
  DSH_PERMISSION_MODE=workspace-write dsh --profile headless "Read TASK.md in the current directory and do the task it describes. Write REPORT.md as it asks." > run.log 2>&1
  ```

- **Permissions**: `workspace-write` blocks writes to the repository and the home directory, but not to other locations under `/tmp` (including other task directories), and it does not restrict reads. Task content is sent to the DeepSeek API, so never put serial numbers, credentials, or other sensitive data in the task directory or `TASK.md`.
- **Review**: `REPORT.md` is only a set of leads to verify. The main agent must check each conclusion, and may use it in code or docs only after it passes. The main agent must also tell me which conclusions were verified and which are still inference.