# Security policy

This is a personal setup guide, maintained by one person. There is no
response-time promise, and nothing here is a supported product.

## Reporting a vulnerability

Report it privately through this repository's **Security** tab: choose
**Report a vulnerability**. This uses GitHub's private vulnerability reporting.
Please do not open a public issue for a vulnerability.

## In scope

- The scripts in `scripts/`, and the patch in `patches/`.
- The configuration they install from `config/`: the firewall rules, the SSH
  settings, the LaunchAgent, and the tailnet policy.
- The docs' instructions about the API key, for example a step that would
  expose it.

## Out of scope

Report these to their own projects:

- mlx-serve: [ddalcu/mlx-serve](https://github.com/ddalcu/mlx-serve). A flaw
  in `patches/inkling2-m1.patch` is in scope; report it here, and it may also
  belong to [namp/mlx-serve-inkling2-m1](https://github.com/namp/mlx-serve-inkling2-m1).
- Tailscale: <https://tailscale.com/security>.
- The model's behavior or output: report it to whoever published the model.
