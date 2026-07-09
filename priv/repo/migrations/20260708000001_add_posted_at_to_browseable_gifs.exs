defmodule NathanForUs.Repo.Migrations.AddPostedAtToBrowseableGifs do
  use Ecto.Migration

  def change do
    alter table(:browseable_gifs) do
      add :posted_at, :utc_datetime
    end

    create index(:browseable_gifs, [:posted_at])
  end
end
