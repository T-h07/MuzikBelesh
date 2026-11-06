# Windows development

Install VS Code, Git, PowerShell, and a GitHub-authenticated Git client. Clone the repository, switch to `feature/phase-00-foundation`, edit Swift/YAML/Markdown files, and commit normally. A Windows Swift compiler is not equivalent to an iOS SDK build from Xcode.

Push the feature branch and use GitHub Actions. `CI` generates the project, resolves packages, selects an available iPhone simulator, builds, and tests. `Build unsigned IPA` builds a generic iOS device app and uploads an unsigned artifact. Inspect the failed step and full log when diagnosing errors.

Typical commands are `git fetch origin`, `git switch feature/phase-00-foundation`, `git status`, `git add .`, `git commit -m "feat(phase-00): establish foundation"`, and `git push origin feature/phase-00-foundation`.

