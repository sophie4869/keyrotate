# Homebrew formula for keyrotate.
#
# To publish: create a public repo named `homebrew-tap` under your GitHub user
# (must be named exactly that — Homebrew adds the `homebrew-` prefix implicitly).
# Then copy this file to Formula/keyrotate.rb in that repo and push.
#
# End-user install becomes:
#   brew install sophie4869/tap/keyrotate
#
# After each `keyrotate` release, update the `url` (new tag) and `sha256`
# (from `shasum -a 256 keyrotate-vX.Y.Z.tar.gz`).

class Keyrotate < Formula
  desc "Rotate & sync secrets across Vercel/Cloud Run/GCP SM/Koyeb/GH Actions/Atlas + local .env"
  homepage "https://github.com/sophie4869/keyrotate"
  url "https://github.com/sophie4869/keyrotate/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 — regenerate on each release:
  #   curl -sL https://github.com/sophie4869/keyrotate/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
  sha256 "REPLACE_WITH_ACTUAL_SHA256_AFTER_TAGGING"
  license "MIT"

  depends_on "jq"
  # gh is optional (only needed for `github` and `userPassword` targets); flagged as recommended
  depends_on "gh" => :recommended
  # openssl is macOS-preinstalled; not declared

  def install
    bin.install "bin/secret" => "secret"
    # Ship the SKILL template + example config as `pkgshare` docs so users can find them
    (pkgshare/"examples").install Dir["examples/*"]
    doc.install "README.md", "SCHEMA.md", "CHANGELOG.md"
  end

  def caveats
    <<~EOS
      keyrotate configs live in ~/.config/keyrotate/*.json
      Alias file (short project names): ~/.config/keyrotate/_aliases.json

      Provider credentials are read from macOS Keychain (services vary by target):
        atlas-api       — MongoDB Atlas Admin API pub/priv key pair
        vercel-api      — Vercel token
        koyeb-api       — Koyeb token
        (gcloud uses its own auth via gcloud CLI)

      See #{opt_share}/keyrotate/README.md for full setup + provider matrix,
      and #{opt_share}/keyrotate/examples/managing-secrets.SKILL.md for
      the Claude Code skill template.
    EOS
  end

  test do
    # Basic smoke — the CLI prints usage when invoked with no args.
    assert_match "secret ls", shell_output("#{bin}/secret 2>&1", 1)
  end
end
