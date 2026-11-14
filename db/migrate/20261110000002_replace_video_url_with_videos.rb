# Exercises carry a list of demo videos from the seeds (#235), each
# { url, title, channel }, in place of the one video_url no seed ever set.
# Both are plain ADD and DROP COLUMN (the sqlite3 gem's SQLite has native
# DROP COLUMN), so no table is copied and no constraint is lost.
Sequel.migration do
  up do
    add_column :exercises, :videos, :json, null: false, default: "[]"
    drop_column :exercises, :video_url
  end

  down do
    add_column :exercises, :video_url, String
    drop_column :exercises, :videos
  end
end
