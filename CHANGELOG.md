# Changelog

All notable changes to this module are documented here. This project adheres to [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

---

## [0.1.0] — 2026-05-29

### Added

- Private VPC module with configurable CIDR and multi-AZ private subnets
- RDS module supporting PostgreSQL and MySQL with encrypted gp3 storage
- Seeder Lambda module that populates a `users` table with a configurable number of dummy rows
- Automatic engine version defaults (postgres 16.3 / mysql 8.0.35)
- Parameter group family derived automatically from engine version string
- Conventional-commit-based release pipeline with `bump-my-version` and `git-cliff`
- Claude Code Review and Claude Code GitHub Actions integrations

---
