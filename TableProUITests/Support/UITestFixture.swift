// Small on purpose: Chinook's 1,000-row Track grid published about 12,800 accessibility elements,
// and every query against its window cost seconds.
internal enum UITestFixture {
    internal static let connectionName = "Fixture"

    internal static let sql = """
        CREATE TABLE artist (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE album (id INTEGER PRIMARY KEY, title TEXT NOT NULL,
                            artist_id INTEGER NOT NULL REFERENCES artist(id));
        CREATE TABLE genre (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE track (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
                            album_id INTEGER REFERENCES album(id), milliseconds INTEGER NOT NULL);
        CREATE INDEX track_album ON track(album_id);
        CREATE TABLE document (id INTEGER PRIMARY KEY, label TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE note (id INTEGER PRIMARY KEY, tag TEXT, body TEXT NOT NULL);
        INSERT INTO artist VALUES (1, 'Ada'), (2, 'Brook'), (3, 'Cole'), (4, 'Dana'), (5, 'Eli');
        INSERT INTO album VALUES (1, 'North', 1), (2, 'South', 2), (3, 'East', 2), (4, 'West', 3),
                                 (5, 'Up', 4), (6, 'Down', 5);
        INSERT INTO genre VALUES (1, 'Rock'), (2, 'Jazz'), (3, 'Metal');
        INSERT INTO track VALUES (1, 'One', 1, 343719), (2, 'Two', 1, 342562), (3, 'Three', 2, 230619),
                                 (4, 'Four', 2, 252051), (5, 'Five', 3, 375418), (6, 'Six', 3, 205662),
                                 (7, 'Seven', 4, 233926), (8, 'Eight', 4, 210834), (9, 'Nine', 5, 203102),
                                 (10, 'Ten', 6, 263497), (11, 'Eleven', 6, 199836), (12, 'Twelve', 6, 215196);
        INSERT INTO document VALUES
          (1, 'First', '{"id": 1, "name": "Acme", "active": true, "tags": ["alpha", "beta"], "limits": {"seats": 25}}'),
          (2, 'Second', '{"id": 2, "name": "Beta", "active": false, "tags": [], "limits": {"seats": 5}}');
        INSERT INTO note VALUES (1, 'todo', 'Buy milk'), (2, 'idea', 'Ship it'), (3, NULL, 'Plain');
        """
}
