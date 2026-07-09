defmodule NathanForUs.Repo.Migrations.DropLegacySocialTables do
  use Ecto.Migration

  @moduledoc """
  Drops tables from the app's previous life as a Nathan Fielder fan site:
  Bluesky firehose posts, the word-approval chat game, the social posts/follows
  experiment, and the viral-gif timeline (replaced by posted_at on browseable_gifs).

  This migration is intentionally irreversible.
  """

  def up do
    drop_if_exists table(:gif_interactions)
    drop_if_exists table(:viral_gifs)
    drop_if_exists table(:chat_messages)
    drop_if_exists table(:words)
    drop_if_exists table(:bluesky_posts)
    drop_if_exists table(:bluesky_users)
    drop_if_exists table(:follows)
    drop_if_exists table(:posts)
  end

  def down do
    raise Ecto.MigrationError, message: "cannot restore dropped legacy social tables"
  end
end
