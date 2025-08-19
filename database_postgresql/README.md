# Database: PostgreSQL Schema for Crowdfund Platform

This folder contains the PostgreSQL schema and helper scripts for the Crowdfund Platform.

Contents:
- startup.sh: boots a local PostgreSQL (preconfigured for this environment)
- migrations/001_init_schema.sql: initial schema for users, projects, rewards, pledges, transactions, auth/session tables
- db_visualizer/: lightweight Node viewer (optional)

How to apply migrations:
1) Ensure PostgreSQL is running (use startup.sh if provided by your environment).
2) Export environment or use the provided db_connection.txt connection string.
3) Apply migration:
   psql postgresql://appuser:dbuser123@localhost:5000/myapp -f database_postgresql/migrations/001_init_schema.sql

Environment variables (provided/expected by container runtime):
- POSTGRES_URL
- POSTGRES_USER
- POSTGRES_PASSWORD
- POSTGRES_DB
- POSTGRES_PORT

Notes:
- Currency codes default to USD/EUR/GBP (extend as needed).
- Business rules enforced via triggers:
  - Slug generation for projects
  - Reward quantity checks and claim increments
  - Tally amount_raised from succeeded transactions (net of fees)
  - Currency consistency across pledges/transactions
  - Basic project status evaluation based on goal and deadline
