# Security Policy

## Supported versions

Only the latest release of PreviewMD receives security fixes. Please check that you can reproduce an issue on the latest version from [GitHub Releases](https://github.com/ychani/Preview-md/releases) before reporting it.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report it privately through GitHub's private vulnerability reporting: go to the repository's **Security** tab and choose **Report a vulnerability** ([direct link](https://github.com/ychani/Preview-md/security/advisories/new)).

Helpful details:

- PreviewMD version and macOS version
- whether the issue affects the app, the Quick Look extension, or both
- a minimal Markdown file or steps that reproduce it

You can expect an acknowledgement within a week. Once a fix ships, the advisory is published with credit to the reporter unless you prefer otherwise.

## Scope

Of particular interest: a Markdown document that can run script, escape the HTML sanitizer, read local files, or make network requests when opened in PreviewMD or previewed with Quick Look.
