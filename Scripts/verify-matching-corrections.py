"""Portable checks of the actual Swift regex/SQL literals; not Swift execution.

Run on Windows with Python 3. No personal library or network access is required.
XCTest and a native device build remain separate verification gates.
"""
from pathlib import Path
import json
import re
import sqlite3
import uuid

ROOT = Path(__file__).resolve().parents[1]


def sql_literal(name):
    source = (ROOT / name).read_text(encoding="utf-8")
    return re.search(r'db.execute\(sql: """(.*?)"""\)', source, re.S).group(1)


def test_metadata_abort():
    source = (ROOT / "OFFLINE/PlaylistMigration/MigrationReadModels.swift").read_text(encoding="utf-8")
    literal = re.search(r'value.range\(of: "(.*?)", options: .regularExpression', source).group(1)
    pattern = re.compile(json.loads('"' + literal + '"'))
    titles = ["Song (Studio)"] * 5 + ["Secret (Studio)"] + ["Song (Studio)"] * 42
    assert next(i for i, title in enumerate(titles) if pattern.search(title)) == 5
    # Execute the credential-syntax literals from the new sanitizer, not a copy.
    corrected = (ROOT / "OFFLINE/PlaylistMigration/Matching/MatchingRecovery.swift").read_text(encoding="utf-8")
    array = re.search(r'for pattern in (\[.*?\]) \{', corrected).group(1)
    patterns = json.loads(array)
    portable = [re.compile(p) for p in patterns if r"\p{Cc}" not in p]
    assert not any(p.search(titles[5]) for p in portable)
    for credential in ["password=private", "Bearer private", "https://example.com/file?sig=private"]:
        assert any(p.search(credential) for p in portable)
    print("PASS: reproduced legacy unsafeDiagnostics predicate at occurrence 6; corrected text policy accepts ordinary title and rejects credential syntax")


def test_schema_upgrade():
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    # Minimal released-table prerequisites; execute actual v013/v014 table SQL.
    db.executescript("""
        CREATE TABLE playlists(id TEXT PRIMARY KEY);
        CREATE TABLE tracks(id TEXT PRIMARY KEY, availability TEXT);
        CREATE TABLE playback_state(scope TEXT PRIMARY KEY, positionMs INTEGER);
        INSERT INTO playlists VALUES ('playlist');
        INSERT INTO tracks VALUES ('audio', 'available');
        INSERT INTO playback_state VALUES ('default', 12345);
    """)
    db.executescript(sql_literal("OFFLINE/PlaylistMigration/MigrationStorageSchema.swift"))
    db.execute("""INSERT INTO playlist_migrations(id,destinationPlaylistID,operationID,source,sourcePlaylistName,
        importFingerprint,expectedEntryCount,status,createdAt,updatedAt)
        VALUES ('session','playlist','operation','exportify','Fixture','fingerprint',200,'metadataReady',1,1)""")
    source_ids = [str(uuid.uuid4()) for _ in range(200)]
    db.executemany("""INSERT INTO migration_entries(id,migrationID,sourcePosition,title,additionalArtists,status,createdAt,updatedAt)
        VALUES (?,'session',?,'Original recording','[]','pending',1,1)""", enumerate_to_args(source_ids))
    before = db.execute("SELECT * FROM migration_entries ORDER BY sourcePosition").fetchall()
    db.executescript(sql_literal("OFFLINE/PlaylistMigration/HybridPlaylistSchema.swift"))
    manual_ids = [str(uuid.uuid4()) for _ in range(3)]
    db.executemany("INSERT INTO playlist_local_occurrences VALUES (?,'playlist','audio',?,1)", enumerate_to_args(manual_ids))
    assert db.execute("SELECT count(*) FROM playlist_local_occurrences").fetchone()[0] == 3
    assert db.execute("SELECT * FROM migration_entries ORDER BY sourcePosition").fetchall() == before
    db.execute("INSERT INTO migration_matching_checkpoints VALUES (?, '10.4.1', 0, 'review', 1)", (source_ids[0],))
    db.execute("INSERT INTO migration_matching_jobs VALUES ('session','running',1)")
    db.execute("DELETE FROM playlist_local_occurrences WHERE id=?", (manual_ids[0],))
    assert db.execute("SELECT count(*) FROM tracks").fetchone()[0] == 1
    db.execute("DELETE FROM tracks WHERE id='audio'")
    assert db.execute("SELECT count(*) FROM playlist_local_occurrences").fetchone()[0] == 0
    assert db.execute("SELECT * FROM migration_entries ORDER BY sourcePosition").fetchall() == before
    assert db.execute("SELECT positionMs FROM playback_state").fetchone()[0] == 12345
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []
    db.execute("DELETE FROM playlists WHERE id='playlist'")
    for table in ["migration_entries", "migration_matching_jobs", "migration_matching_checkpoints"]:
        assert db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0
    print("PASS: actual additive schema SQL, 200 unchanged source occurrences, independent duplicates, removal, FK cascades, checkpoints and preserved playback position")


def enumerate_to_args(ids):
    return [(identifier, position) for position, identifier in enumerate(ids)]


if __name__ == "__main__":
    test_metadata_abort()
    test_schema_upgrade()
