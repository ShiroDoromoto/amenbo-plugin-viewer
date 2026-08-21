package main

import (
	"embed"
	"fmt"
	"io/fs"
	"path"
	"sort"
	"strconv"
	"strings"
)

// The database in the user's own account is not laid out once and left. Migrations are added
// here as the Worker learns to hold more, and every one of them has to reach a database that was
// stood up before it existed — in an account nobody here can log in to, on a day nobody chooses.
//
// **So which migrations a database has had is a thing the database itself says.** Guessing it
// from the outside is what the first version did: it asked whether the `records` table was there
// and, if it was, left everything alone. That reads as "already set up" for a database laid out
// by any older release, so a migration added afterwards would never be applied — and what breaks
// is the user's next send, in an account with no way to see it from here.

// The migrations, baked in at build time in the order they were written. They are the Worker's
// own `migrations/`, copied here file by file under the same names by the Worker's build.
//
// **Generated. Edit worker/migrations/, never these.**
//
//go:embed migrations/*.sql
var workerMigrations embed.FS

const migrationsHere = "migrations"

// ledgerTable is where a database records which migrations it has had, and both the name and the
// shape are wrangler's rather than ours. A user who later reaches for `wrangler d1 migrations`
// against their own database finds the ledger it expects, and the tests — which apply the same
// migrations through `applyD1Migrations` — write into the same table under the same names.
// A second ledger of our own would let the two disagree without either being wrong.
const ledgerTable = "d1_migrations"

const createTheLedger = `CREATE TABLE IF NOT EXISTS d1_migrations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT UNIQUE,
  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);`

// tablesThatSayWhereADatabaseStands asks the two questions that place a database that was
// already there: has it been laid out at all, and does it say what it has had.
const tablesThatSayWhereADatabaseStands = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('records', 'd1_migrations')"

const readTheLedger = "SELECT name FROM d1_migrations"

// laidDownBeforeTheLedger is what a database with tables but no ledger has already had.
//
// **It is a frozen list, not the migrations this build carries.** Releases before this one laid
// the whole schema down in one go and recorded nothing, so the only honest thing to say about
// such a database is which migrations existed back then — and that is these two, which is all
// v1 shipped. Reading it off the current build instead would mark every future migration as
// applied on exactly the databases that have not had it.
var laidDownBeforeTheLedger = []string{
	"0001_records_and_tokens.sql",
	"0002_where_the_order_stands.sql",
}

// migration is one file of the run: the name a database records having had, and the SQL it is.
type migration struct {
	name string
	sql  string
}

// theMigrations reads what is baked in, in the order they are to be applied.
//
// The order is the number each name starts with, which is how `readD1Migrations` sorts the same
// files for the tests. The names are zero-padded, so it is also plain alphabetical order — but
// the padding is a convention somebody could break, and the number is what the convention is
// for.
func theMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(workerMigrations, migrationsHere)
	if err != nil {
		return nil, fmt.Errorf("this build carries no migrations: %w", err)
	}

	migrations := make([]migration, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		sql, err := fs.ReadFile(workerMigrations, path.Join(migrationsHere, entry.Name()))
		if err != nil {
			return nil, err
		}
		migrations = append(migrations, migration{name: entry.Name(), sql: string(sql)})
	}
	if len(migrations) == 0 {
		return nil, fmt.Errorf("this build carries no migrations")
	}
	sort.SliceStable(migrations, func(i, j int) bool {
		return numbering(migrations[i].name) < numbering(migrations[j].name)
	})
	return migrations, nil
}

// numbering is the number a migration's name starts with. A name that does not start with one
// sorts first, which puts it where it will be noticed rather than silently last.
func numbering(name string) int {
	digits := name
	if cut := strings.Index(name, "_"); cut >= 0 {
		digits = name[:cut]
	}
	number, err := strconv.Atoi(digits)
	if err != nil {
		return -1
	}
	return number
}

// standing is what a database that was already there says about itself.
type standing struct {
	// laidOut: it has the tables, so something has been applied to it.
	laidOut bool
	// keepsALedger: it says what it has had, so nothing has to be assumed.
	keepsALedger bool
	// had: the migrations it has already been given.
	had []string
}

func (s standing) has(name string) bool {
	for _, already := range s.had {
		if already == name {
			return true
		}
	}
	return false
}

// whereTheDatabaseStands works out what has already been applied.
//
// A database made a moment ago has had nothing, and there is nothing to ask it. One that was
// already there is asked, in this order: its ledger if it keeps one, and the frozen list if it
// has tables but no ledger. A database with neither is one an interrupted run left empty, and
// gets everything.
func whereTheDatabaseStands(air sky, account, database string, fresh bool) (standing, error) {
	if fresh {
		return standing{}, nil
	}

	outcomes, err := air.query(account, database, tablesThatSayWhereADatabaseStands)
	if err != nil {
		return standing{}, err
	}
	var where standing
	for _, outcome := range outcomes {
		for _, row := range outcome.Results {
			switch named(row) {
			case "records":
				where.laidOut = true
			case ledgerTable:
				where.keepsALedger = true
			}
		}
	}

	switch {
	case where.keepsALedger:
		outcomes, err := air.query(account, database, readTheLedger)
		if err != nil {
			return standing{}, err
		}
		for _, outcome := range outcomes {
			for _, row := range outcome.Results {
				if name := named(row); name != "" {
					where.had = append(where.had, name)
				}
			}
		}
	case where.laidOut:
		where.had = laidDownBeforeTheLedger
	}
	return where, nil
}

// named reads the `name` column off a row D1 handed back.
func named(row map[string]any) string {
	name, _ := row["name"].(string)
	return name
}

// quoted puts a string into SQL as a literal. The names are this repository's own filenames, so
// there is nothing here to escape — which is exactly why doing it anyway costs nothing.
func quoted(text string) string {
	return "'" + strings.ReplaceAll(text, "'", "''") + "'"
}

// recordThat is the line that marks one migration as had. It goes in the same call as the
// migration it records, so a run that fails part way through leaves the ledger saying what
// actually landed rather than what was meant to.
func recordThat(name string) string {
	return fmt.Sprintf("INSERT INTO %s (name) VALUES (%s);", ledgerTable, quoted(name))
}

// layTheSchemaDown brings the database up to what this build carries, and applies nothing it has
// already had.
//
// The whole run goes over in one call, migrations and ledger lines together: D1 takes the
// statements in order and stops at the first that fails, so what is recorded as applied is what
// applied.
func layTheSchemaDown(air sky, account, database string, fresh bool) error {
	where, err := whereTheDatabaseStands(air, account, database, fresh)
	if err != nil {
		return err
	}
	migrations, err := theMigrations()
	if err != nil {
		return err
	}

	var missing []migration
	for _, one := range migrations {
		if !where.has(one.name) {
			missing = append(missing, one)
		}
	}
	if where.keepsALedger && len(missing) == 0 {
		logf("%s: the database is up to date — nothing to apply", pluginName)
		return nil
	}

	var run strings.Builder
	run.WriteString(createTheLedger + "\n")
	// A database laid out before the ledger existed is given one that says what it has, rather
	// than one that says it has nothing — which would re-apply the very tables it is standing on.
	if !where.keepsALedger {
		for _, name := range where.had {
			run.WriteString(recordThat(name) + "\n")
		}
	}
	for _, one := range missing {
		run.WriteString(one.sql)
		if !strings.HasSuffix(one.sql, "\n") {
			run.WriteString("\n")
		}
		run.WriteString(recordThat(one.name) + "\n")
	}

	if _, err := air.query(account, database, run.String()); err != nil {
		return err
	}

	switch {
	case len(missing) == len(migrations):
		logf("%s: the schema is in", pluginName)
	case len(missing) == 0:
		logf("%s: the database already had every migration — what it has had is written down now", pluginName)
	default:
		logf("%s: %d migration(s) applied, up to %s", pluginName, len(missing), missing[len(missing)-1].name)
	}
	return nil
}
