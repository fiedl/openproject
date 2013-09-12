class AwesomeLegacyJournalsMigration < ActiveRecord::Migration

  class UnsupportedWikiContentJournalCompressionError < ::StandardError
  end

  class AmbiguousJournalsError < ::StandardError
  end

  class AmbiguousAttachableJournalError < AmbiguousJournalsError
  end

  class AmbiguousCustomizableJournalError < AmbiguousJournalsError
  end

  class IncompleteJournalsError < ::StandardError
  end


  def up
    check_assumptions

    legacy_journals = fetch_legacy_journals

    puts "Migrating #{legacy_journals.count} legacy journals."

    legacy_journals.each_with_index do |legacy_journal, count|

      type = legacy_journal["type"]

      migrator = get_migrator(type)

      if migrator.nil?
        ignored[type] += 1

        next
      end

      migrator.migrate(legacy_journal)

      if count > 0 && (count % 1000 == 0)
        puts "#{count} journals migrated"
      end
    end

    ignored.each do |type, amount|
      puts "#{type} was ignored #{amount} times"
    end
  end

  def down
  end

  private


  def ignored
    @ignored ||= Hash.new do |k, v|
      0
    end
  end

  def get_migrator(type)
    @migrators ||= begin

      {
        "AttachmentJournal" => attachment_migrator,
        "ChangesetJournal" => changesets_migrator,
        "NewsJournal" => news_migrator,
        "MessageJournal" => message_migrator,
        "WorkPackageJournal" => work_package_migrator,
        "IssueJournal" => work_package_migrator,
        "Timelines_PlanningElementJournal" => work_package_migrator,
        "TimeEntryJournal" => time_entry_migrator,
        "WikiContentJournal" => wiki_content_migrator
      }
    end

    @migrators[type]
  end

  def attachment_migrator
    LegacyJournalMigrator.new("AttachmentJournal", "attachment_journals")
  end

  def changesets_migrator
    LegacyJournalMigrator.new("ChangesetJournal", "changeset_journals")
  end

  def news_migrator
    LegacyJournalMigrator.new("NewsJournal", "news_journals")
  end

  def message_migrator
    LegacyJournalMigrator.new("MessageJournal", "message_journals")
  end

  def work_package_migrator
    LegacyJournalMigrator.new "WorkPackageJournal", "work_package_journals" do
      def migrate_key_value_pairs!(keys, values, legacy_journal, journal_id)
        attachments = keys.select { |d| d =~ /attachments_.*/ }
        attachments.each do |k|

          attachment_id = k.split("_").last.to_i

          attachable = ActiveRecord::Base.connection.select_all <<-SQL
            SELECT *
            FROM #{attachable_table_name} AS a
            WHERE a.journal_id = #{quote_value(journal_id)} AND a.attachment_id = #{attachment_id};
          SQL

          if attachable.size > 1

            raise AmbiguousAttachableJournalError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              It appears there are ambiguous attachable journal data.
              Please make sure attachable journal data are consistent and
              that the unique constraint on journal_id and attachment_id
              is met.
            MESSAGE

          elsif attachable.size == 0

            db_execute <<-SQL
              INSERT INTO #{attachable_table_name}(journal_id, attachment_id)
              VALUES (#{quote_value(journal_id)}, #{quote_value(attachment_id)});
            SQL
          end

          j = keys.index(k)
          [keys, values].each { |a| a.delete_at(j) }
        end

        custom_values = keys.select { |d| d =~ /custom_values.*/ }
        custom_values.each do |k|

          custom_field_id = k.split("_values").last.to_i
          value = values[keys.index k]

          customizable = ActiveRecord::Base.connection.select_all <<-SQL
            SELECT *
            FROM #{customizable_table_name} AS a
            WHERE a.journal_id = #{quote_value(journal_id)} AND a.custom_field_id = #{custom_field_id};
          SQL

          if customizable.size > 1

            raise AmbiguousCustomizableJournalError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              It appears there are ambiguous customizable journal
              data. Please make sure customizable journal data are
              consistent and that the unique constraint on journal_id and
              custom_field_id is met.
            MESSAGE

          elsif customizable.size == 0

            db_execute <<-SQL
              INSERT INTO #{customizable_table_name}(journal_id, custom_field_id, value)
              VALUES (#{quote_value(journal_id)}, #{quote_value(custom_field_id)}, #{quote_value(value)});
            SQL
          end

          j = keys.index(k)
          [keys, values].each { |a| a.delete_at(j) }

        end
      end
    end
  end

  def time_entry_migrator
    LegacyJournalMigrator.new("TimeEntryJournal", "time_entry_journals")
  end

  def wiki_content_migrator

    LegacyJournalMigrator.new("WikiContentJournal", "wiki_content_journals") do

      def migrate_key_value_pairs!(keys, values, legacy_journal, journal_id)
        if keys.index("lock_version").nil?
          keys.push "lock_version"
          values.push legacy_journal["version"]
        end

        if !(data_index = keys.index("data")).nil?

          compression_index = keys.index("compression")
          compression = values[compression_index]

          if !compression.empty?

            raise UnsupportedWikiContentJournalCompressionError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
              There is a WikiContent journal that contains data in an
              unsupported compression: #{compression}
            MESSAGE

          end

          keys[data_index] = "text"

          keys.delete_at(compression_index)
          values.delete_at(compression_index)
        end
      end

    end
  end

  # fetches legacy journals. might me empty.
  def fetch_legacy_journals

    attachments_and_changesets = ActiveRecord::Base.connection.select_all <<-SQL
      SELECT *
      FROM #{quoted_legacy_journals_table_name} AS j
      WHERE (j.activity_type = #{quote_value("attachments")})
        OR (j.activity_type = #{quote_value("custom_fields")})
      ORDER BY j.journaled_id, j.activity_type, j.version;
    SQL

    remainder = ActiveRecord::Base.connection.select_all <<-SQL
      SELECT *
      FROM #{quoted_legacy_journals_table_name} AS j
      WHERE NOT ((j.activity_type = #{quote_value("attachments")})
        OR (j.activity_type = #{quote_value("custom_fields")}))
      ORDER BY j.journaled_id, j.activity_type, j.version;
    SQL

    attachments_and_changesets + remainder
  end

  def quoted_legacy_journals_table_name
    @quoted_legacy_journals_table_name ||= quote_table_name 'legacy_journals'
  end

  def check_assumptions

    # SQL finds all those journals whose has more or less predecessors than
    # it's version would require. Ignores the first journal.
    # e.g. a journal with version 5 would have to have 5 predecessors
    invalid_journals = ActiveRecord::Base.connection.select_values <<-SQL
      SELECT DISTINCT tmp.id
      FROM (
        SELECT
          a.id AS id,
          a.journaled_id,
          a.type,
          a.version AS version,
          count(b.id) AS count
        FROM
          #{quoted_legacy_journals_table_name} AS a
        LEFT JOIN
          #{quoted_legacy_journals_table_name} AS b
          ON a.version >= b.version
            AND a.journaled_id = b.journaled_id
            AND a.type = b.type
        WHERE a.version > 1
        GROUP BY
          a.id,
          a.journaled_id,
          a.type,
          a.version
      ) AS tmp
      WHERE
        NOT (tmp.version = tmp.count);
    SQL

    unless invalid_journals.empty?

      raise IncompleteJournalsError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
        It appears there are incomplete journals. Please make sure
        journals are consistent and that for every journal, there is an
        initial journal containing all attribute values at the time of
        creation. The offending journal ids are: #{invalid_journals}
      MESSAGE
    end
  end

  module DbWorker
    def quote_value(name)
      ActiveRecord::Base.connection.quote name
    end

    def quoted_table_name(name)
      ActiveRecord::Base.connection.quote_table_name name
    end

    def db_columns(table_name)
      ActiveRecord::Base.connection.columns table_name
    end

    def db_select_all(statement)
      ActiveRecord::Base.connection.select_all statement
    end

    def db_execute(statement)
      ActiveRecord::Base.connection.execute statement
    end
  end

  include DbWorker

  class LegacyJournalMigrator
    include DbWorker

    attr_accessor :table_name,
                  :type,
                  :journable_class

    def initialize(type=nil, table_name=nil, &block)
      self.table_name = table_name
      self.type = type

      instance_eval &block if block_given?

      if table_name.nil? || type.nil?
        raise ArgumentError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
        table_name and type have to be provided. Either as parameters or set within the block.
        MESSAGE
      end

      self.journable_class = self.type.gsub(/Journal$/, "")
    end

    def column_names
      @column_names ||= db_columns(table_name).map(&:name)
    end

    def migrate(legacy_journal)

      journaled_id, version = legacy_journal["journaled_id"], legacy_journal["version"]

      # turn id fields into integers.
      ["id", "journaled_id", "user_id", "version"].each do |f|
        legacy_journal[f] = legacy_journal[f].to_i
      end

      legacy_journal["changed_data"] = YAML.load(legacy_journal["changed_data"])

      # actually insert/update stuff in the database.
      journal = get_journal(journaled_id, version)
      journal_id = journal["id"]

      combined_journal = combine_journal(journaled_id, legacy_journal)


      existing_journal = fetch_existing_journal_data(journal_id)

      to_insert = combined_journal.inject({}) do |mem, (key, value)|
        if column_names.include?(key)
          # The old journal's values attribute was structured like
          # [old_value, new_value]
          # We only need the new_value
          mem[key] = value.last
        end

        mem
      end

      keys = to_insert.keys
      values = to_insert.values

      migrate_key_value_pairs!(keys, values, legacy_journal, journal_id)

      if existing_journal.size > 1

        raise AmbiguousJournalsError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
          It appears there are ambiguous journal data. Please make sure
          journal data are consistent and that the unique constraint on
          journal_id is met.
        MESSAGE

      elsif existing_journal.size == 0
        db_execute <<-SQL
          INSERT INTO #{journal_table_name} (journal_id#{", " + keys.map{|k| map_key(k) }.join(", ") unless keys.empty? })
          VALUES (#{quote_value(journal_id)}#{", " + values.map{|d| quote_value(d)}.join(", ") unless values.empty?});
        SQL

        existing_journal = fetch_existing_journal_data(journal_id)
      end

      existing_journal = existing_journal.first

      sql_statements = <<-SQL
        UPDATE journals
           SET journable_data_id   = #{quote_value(journal_id)},
               journable_data_type = #{quote_value(type)},
               user_id             = #{quote_value(legacy_journal["user_id"])},
               notes               = #{quote_value(legacy_journal["notes"])},
               created_at          = #{quote_value(legacy_journal["created_at"])},
               activity_type       = #{quote_value(legacy_journal["activity_type"])}
         WHERE id = #{quote_value(journal_id)};
      SQL

      sql_statements = <<-SQL + sql_statements unless keys.empty?
        UPDATE #{journal_table_name}
           SET #{(keys.each_with_index.map {|k,i| "#{map_key(k)} = #{quote_value(values[i])}"}).join(", ")}
         WHERE id = #{existing_journal["id"]};
      SQL

      db_execute sql_statements
    end

    protected

    def combine_journal(journaled_id, legacy_journal)
      # compute the combined journal from current and all previous changesets.
      combined_journal = legacy_journal["changed_data"]
      if previous.journaled_id == journaled_id
        combined_journal = previous.journal.merge(combined_journal)
      end

      # remember the combined journal as the previous one for the next iteration.
      previous.set(combined_journal, journaled_id, type)

      combined_journal
    end

    def previous
      @previous ||= PreviousState.new({}, 0, "")
    end

    # here to be overwritten by instances
    def migrate_key_value_pairs!(keys, values, legacy_journal, journal_id) end

    # fetches specific journal data row. might be empty.
    def fetch_existing_journal_data(journal_id)
      ActiveRecord::Base.connection.select_all <<-SQL
        SELECT *
        FROM #{journal_table_name} AS d
        WHERE d.journal_id = #{quote_value(journal_id)};
      SQL
    end

    def map_key(key)
      case key
      when "issue_id"
        "work_package_id"
      else
        key
      end
    end

    def customizable_table_name
      quoted_table_name("customizable_journals")
    end

    def attachable_table_name
      quoted_table_name("attachable_journals")
    end

    def journal_table_name
      quoted_table_name(table_name)
    end

    # gets a journal row, and makes sure it has a valid id in the database.
    def get_journal(id, version)
      journal = fetch_journal(id, version)

      if journal.size > 1

        raise AmbiguousJournalsError, <<-MESSAGE.split("\n").map(&:strip!).join(" ") + "\n"
          It appears there are ambiguous journals. Please make sure
          journals are consistent and that the unique constraint on id,
          type and version is met.
        MESSAGE

      elsif journal.size == 0

        db_execute <<-SQL
          INSERT INTO #{quoted_journals_table_name}(journable_id, journable_type, version, created_at)
          VALUES (
            #{quote_value(id)},
            #{quote_value(journable_class)},
            #{quote_value(version)},
            #{quote_value(Time.now)}
          );
        SQL

        journal = fetch_journal(id, version)
      end

      journal.first
    end

    # fetches specific journal row. might be empty.
    def fetch_journal(id, version)
      db_select_all <<-SQL
        SELECT *
        FROM #{quoted_journals_table_name} AS j
        WHERE j.journable_id = #{quote_value(id)}
          AND j.journable_type = #{quote_value(journable_class)}
          AND j.version = #{quote_value(version)};
      SQL
    end

    def quoted_journals_table_name
      @quoted_journals_table_name ||= quoted_table_name 'journals'
    end
  end

  class PreviousState < Struct.new(:journal, :journaled_id, :type)
    def set(journal, journaled_id, type)
      self.journal = journal
      self.journaled_id = journaled_id
      self.type = type
    end
  end

end
