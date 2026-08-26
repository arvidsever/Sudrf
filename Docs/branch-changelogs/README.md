# Branch changelogs

This directory holds draft changelogs for feature branches that are not yet the
public release history.

The public release changelog remains `changelog/changelog-vX.YY.ZZ.md` (second
and third segments zero-padded to two digits so the directory sorts in version
order; the version itself stays plain semver). Move a branch draft there only
when the branch is merged/released and the final version number is known. A new
user-facing feature or data source increments the minor segment and resets the
patch segment; fixes, cosmetics, retraining without a new product capability,
and developer-only tools increment the patch segment. Every merged branch gets
its own number under that classification, even when no separate build was cut.

## For opencode

The draft `0.38.x` changelogs from the captcha/opencode branch were moved out
of the public `changelog/` directory and now live in:

`Docs/branch-changelogs/captcha-auto-solver/`

Keep editing the branch-local copies there while the branch is not the released
line. When that work ships, move the final notes back into
`changelog/changelog-vX.YY.ZZ.md` and update the app version at the same time.
