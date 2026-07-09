defmodule NathanForUs.Repo.Migrations.AddApiKeyToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :api_key, :string
    end

    create unique_index(:users, [:api_key])

    # Backfill existing accounts so everyone can use the personal-key ingest
    # flow without a regenerate step. gen_random_uuid() is built in (PG 13+),
    # so no pgcrypto dependency; two UUIDs give 256 bits of randomness.
    execute """
    UPDATE users
    SET api_key = 'fc_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
    WHERE api_key IS NULL
    """
  end

  def down do
    alter table(:users) do
      remove :api_key
    end
  end
end
