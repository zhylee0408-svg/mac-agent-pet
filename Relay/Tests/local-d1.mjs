import { DatabaseSync } from "node:sqlite";

class LocalD1Statement {
  constructor(database, sql, bindings = []) {
    this.database = database;
    this.sql = sql;
    this.bindings = bindings;
  }

  bind(...values) {
    return new LocalD1Statement(this.database, this.sql, values);
  }

  #statement() {
    return this.database.prepare(this.sql);
  }

  async first(columnName = undefined) {
    const row = this.#statement().get(...this.bindings);
    if (columnName === undefined) return row;
    return row?.[columnName] ?? null;
  }

  async all() {
    return {
      success: true,
      results: this.#statement().all(...this.bindings),
      meta: { changes: 0 },
    };
  }

  async run() {
    return this.runSynchronously();
  }

  runSynchronously() {
    const result = this.#statement().run(...this.bindings);
    return {
      success: true,
      results: [],
      meta: {
        changes: Number(result.changes),
        last_row_id: Number(result.lastInsertRowid),
      },
    };
  }
}

export class LocalD1Database {
  constructor(migrationSQL) {
    this.database = new DatabaseSync(":memory:");
    this.database.exec(migrationSQL);
  }

  prepare(sql) {
    return new LocalD1Statement(this.database, sql);
  }

  async batch(statements) {
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const results = statements.map((statement) => statement.runSynchronously());
      this.database.exec("COMMIT");
      return results;
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
  }

  close() {
    this.database.close();
  }
}
