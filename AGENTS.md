# Development

* Always add or modify tests for changes
* Ensure build works
* When testing build, ensure app opens in background, not foreground
* Create fixtures to test with data, rather than asking for permission to directories with data
* Do not ask for accessibility permissions to test things, find another way
* Back up app's saved user data, or use a different location for user data when testing, and restore after committing changes

# Release

* Build main, ensure tests pass and build completes, push main branch, create new release with notes of changes, follow format of previous releases. Unless specified, prompt user whether the release should be patch, minor or major.
