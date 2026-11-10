
Target platform: iOS 17.3, jailbroken with [Dopamine RootHide 3](https://github.com/roothide/Dopamine-roothide).

Write README.md, code comments, and git commit messages in English, and always answer my questions in Chinese.

Write code according to the best long-term solution.

When developing a tweak, follow [docs/develop-tweaks.md](docs/develop-tweaks.md).

When releasing a tweak, follow [docs/release-tweaks.md](docs/release-tweaks.md).

No dynamic debugging unless I explicitly ask for it. Do not launch apps on the device, read device logs, or add runtime probes (such as code that dumps a class's methods) to find out how an app behaves. Approval to install a package covers that install only. When a class or method cannot be found, use static analysis of the decrypted binary through IDA MCP, or ask me.


## IDA MCP

For decompilation work, use IDA MCP to analyze the decrypted binary. Use a subagent for large, independent analysis tasks when useful, and review its results before relying on them.

- **Open the target**: Use `open_database` with the decrypted binary or an existing IDA database. Use `list_databases` when multiple databases are open.
- **Query the database**: Use `reference` to look up the current IDA Python API, then use `execute_python` for decompilation, disassembly, functions, strings, types, and cross references.
- **Keep artifacts outside the repository**: Place transient analysis databases and generated files in a dedicated directory such as `/tmp/ida-<task>/`. Copy only reviewed reports worth keeping into `analysis/`, which is git-ignored.
- **Require evidence**: Every conclusion must cite function names, addresses, and relevant instructions or pseudocode. State confirmed facts separately from inference.
- **Review results**: Treat generated reports as leads. The main agent must verify each conclusion before using it in code or documentation, and must tell me which conclusions are confirmed and which remain inference.
