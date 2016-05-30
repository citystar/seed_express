module SeedExpress
  class Abstract
    require 'pp'
    require 'msgpack'

    attr_accessor :table_name
    attr_accessor :truncate_mode
    attr_accessor :force_update_mode
    attr_accessor :nvl_mode
    attr_accessor :datetime_offset
    attr_accessor :callbacks
    attr_accessor :parent_validation

    @@table_to_klasses = nil

    DEFAULT_NVL_CONVERSIONS = {
      :integer => 0,
      :string => '',
    }

    DEFAULT_CONVERSIONS = {
      :datetime => ->(seed_express, value) { Time.zone.parse(value) + seed_express.datetime_offset },
    }

    def initialize(table_name, path, options)
      @table_name = table_name
      @path = path

      @filter_proc = options[:filter_proc]
      default_callback_proc = Proc.new { |*args| }
      default_callbacks = [:truncating, :disabling_record_cache,
                           :reading_data, :deleting,
                           :inserting, :inserting_a_part,
                           :updating, :updating_a_part,
                           :updating_digests, :updating_a_part_of_digests,
                           :inserting_digests, :inserting_a_part_of_digests,
                           :making_bulk_digest_records, :making_a_part_of_bulk_digest_records,
                          ].flat_map do |v|
        ["before_#{v}", "after_#{v}"].map(&:to_sym)
      end.flat_map { |v| [v, default_callback_proc ] }
      default_callbacks = Hash[*default_callbacks]
      @callbacks = default_callbacks.merge(options[:callbacks] || {})

      self.truncate_mode = options[:truncate_mode]
      self.force_update_mode = options[:force_update_mode]
      self.nvl_mode = options[:nvl_mode]
      self.datetime_offset = options[:datetime_offset] || 0
      self.parent_validation = options[:parent_validation]
    end

    def klass
      return @klass if @klass
      @klass = self.class.table_to_klasses[@table_name]
      unless @klass
        raise "#{@table_name} isn't able to convert to a class object"
      end

      @klass
    end

    def seed_table
      @seed_table ||= SeedTable.get_record(@table_name)
    end

    def table_digest
      return @table_digest if @table_digest
      @table_digest = Digest::SHA1.hexdigest(File.read(file_name))
    end

    def truncate_table
      callbacks[:before_truncating].call
      klass.connection.execute("TRUNCATE TABLE #{@table_name};")
      SeedRecord.where(seed_table_id: seed_table.id).delete_all
      callbacks[:after_truncating].call
    end

    def disable_record_cache
      callbacks[:before_disabling_record_cache].call
      seed_table.disable_record_cache
      callbacks[:after_disabling_record_cache].call
    end

    def in_records
      raise "Please implements #in_records in each class"
    end

    def duplicate_ids(values)
      hash = Hash.new(0)
      values.each do |value|
        hash[value[:id]] += 1
      end
      hash.delete_if do |k, v|
        v == 1
      end

      hash
    end

    def import_csv
      if truncate_mode
        truncate_table
      elsif force_update_mode
        disable_record_cache
      elsif seed_table.digest == table_digest
        # テーブルのダイジェスト値が同じ場合は処理をスキップする
        return {:result => :skipped}
      end

      # 削除されるレコードを削除
      deleted_ids = delete_missing_data

      # 新規登録対象と更新対象に分離
      inserting_records, updating_records, digests = take_out_each_types_of_data_to_upload

      # 新規登録するレコードを更新
      inserted_ids, inserted_error = insert_records(inserting_records)

      # 更新するレコードを更新
      updated_ids, actual_updated_ids, updated_error = update_records(updating_records)

      # 不要な digest を削除
      delete_waste_seed_records

      # 処理後の Validation
      after_seed_express_error =
        after_seed_express_validation(:inserted_ids       => inserted_ids,
                                      :updated_ids        => updated_ids,
                                      :actual_updated_ids => actual_updated_ids,
                                      :deleted_ids        => deleted_ids)

      # 処理後の Validation 予約(親テーブルを更新)
      update_parent_digest_to_validate(:inserted_ids       => inserted_ids,
                                       :updated_ids        => updated_ids,
                                       :actual_updated_ids => actual_updated_ids,
                                       :deleted_ids        => deleted_ids)

      has_an_error = inserted_error || updated_error || after_seed_express_error
      unless has_an_error
        # ダイジェスト値の更新
        update_digests(inserted_ids, updated_ids, digests)

        # テーブルダイジェストを更新
        seed_table.update_attributes!(:digest => table_digest)
      end

      result = has_an_error ? :error : :result

      return {
        :result               => result,
        :inserted_count       => inserted_ids.size,
        :updated_count        => updated_ids.size,
        :actual_updated_count => actual_updated_ids.size,
        :deleted_count        => deleted_ids.size
      }
    end

    def convert_value(column, value)
      if value.nil?
        return defaults_on_db[column] if defaults_on_db.has_key?(column)
        return nvl(column, value)
      end
      conversion = DEFAULT_CONVERSIONS[columns[column].type]
      return value unless conversion
      conversion.call(self, value)
    end

    def defaults_on_db
      return @defaults_on_db if @defaults_on_db
      @defaults_on_db = {}
      klass.columns.each do |column|
        unless column.default.nil?
          @defaults_on_db[column.name.to_sym] = column.default
        end
      end
      @defaults_on_db
    end

    def nvl(column, value)
      return nil unless nvl_mode
      nvl_columns[column]
    end

    def nvl_columns
      return @nvl_columns if @nvl_columns
      @nvl_columns = {}
      klass.columns.each do |column|
        @nvl_columns[column.name.to_sym] = DEFAULT_NVL_CONVERSIONS[column.type]
      end

      @nvl_columns
    end

    def columns
      return @columns if @columns
      @columns = klass.columns.index_by { |column| column.name.to_sym }
      @columns.default_proc = lambda { |h, k| raise "#{klass.to_s}##{k} is not found" }
      @columns
    end

    def existing_ids
      return @existing_ids if @existing_ids

      @existing_ids = {}
      klass.select(:id).map(&:id).each do |id|
        @existing_ids[id] = true
      end

      @existing_ids
    end

    def delete_missing_data
      new_ids = in_records.map { |value| value[:id] }
      delete_target_ids = existing_ids.keys - new_ids
      if delete_target_ids.present?
        callbacks[:before_deleting].call(delete_target_ids.size)
        klass.where(id: delete_target_ids).delete_all
      end

      callbacks[:after_deleting].call(delete_target_ids.size)
      delete_target_ids
    end

    def existing_digests
      existing_digests = {}
      SeedRecord.where(seed_table_id: seed_table.id).map do |record|
        existing_digests[record.record_id] = record.digest
      end

      existing_digests
    end

    def take_out_each_types_of_data_to_upload
      inserting_records = []
      updating_records = []
      digests = {}

      duplicate_ids = duplicate_ids(in_records)
      if duplicate_ids.present?
        raise "There are dupilcate ids. ({id=>num}: #{duplicate_ids.inspect})"
      end

      existing_digests = self.existing_digests
      in_records.each do |value|
        id = value[:id]
        digest  = Digest::SHA1.hexdigest(MessagePack.pack(value))

        if existing_ids[id]
          if existing_digests[id] != digest
            updating_records << value
            digests[id] = digest
          end
        else
          inserting_records << value
          digests[id] = digest
        end
      end

      return inserting_records, updating_records, digests
    end

    def insert_records(records)
      error = false
      records_count = records.size
      callbacks[:before_inserting].call(records_count)
      block_size = 1000

      existing_record_count =
        ActiveRecord::Base.transaction { klass.count }  # To read from master server

      inserted_ids = []
      while(records.present?) do
        callbacks[:before_inserting_a_part].call(inserted_ids.size, records_count)
        targets = records.slice!(0, block_size)

        # マスタ本体をアップデート
        bulk_records = targets.map do |attributes|
          model = klass.new
          attributes.each_pair do |column, value|
            model[column] = convert_value(column, value)
          end

          if model.valid?
            inserted_ids << attributes[:id]
            model
          else
            STDOUT.puts
            STDOUT.puts "When id is #{model.id}: "
            STDOUT.print get_errors(model.errors).pretty_inspect
            error = true
            nil
          end
        end.compact
        v = klass.import(bulk_records, :on_duplicate_key_update => [:id])
        callbacks[:after_inserting_a_part].call(inserted_ids.size, records_count)
      end

      current_record_count =
        ActiveRecord::Base.transaction { klass.count }  # To read from master server
      if current_record_count != existing_record_count + records_count
        raise "Inserting error has been detected. Maybe it's caused by duplicated key on not ID column. Try truncate mode."
      end

      callbacks[:after_inserting].call(inserted_ids.size)
      return inserted_ids, error
    end

    def update_records(records)
      error = false
      records_count = records.size
      callbacks[:before_updating].call(records_count)
      block_size = 1000

      updated_ids = []
      actual_updated_ids = []
      while(records.present?) do
        callbacks[:before_updating_a_part].call(updated_ids.size, records_count)
        targets = records.slice!(0, block_size)
        record_ids = targets.map { |target| target[:id] }

        existing_records = klass.where(id: record_ids).index_by(&:id)
        ActiveRecord::Base.transaction do
          bulk_seed_records = []
          targets.each do |attributes|
            id = attributes[:id]
            model = existing_records[id]
            attributes.each_pair do |column, value|
              model[column] = convert_value(column, value)
            end
            if model.changed?
              if model.valid?
                model.save!
                actual_updated_ids << id
              else
                STDOUT.puts
                STDOUT.puts "When id is #{model.id}: "
                STDOUT.print get_errors(model.errors).pretty_inspect
                error = true
              end
            end
            updated_ids << id
          end
          SeedRecord.import(bulk_seed_records)
        end
        callbacks[:before_updating_a_part].call(updated_ids.size, records_count)
      end

      callbacks[:after_updating].call(updated_ids.size)
      return updated_ids, actual_updated_ids, error
    end

    def delete_waste_seed_records
      master_record_ids = klass.all.map(&:id)
      seed_record_ids = SeedRecord.where(seed_table_id: seed_table.id).map(&:record_id)
      waste_record_ids = seed_record_ids - master_record_ids

      SeedRecord.where(seed_table_id: seed_table.id,
                       record_id: waste_record_ids).delete_all
    end

    def update_digests(inserted_ids, updated_ids, digests)
      tmp_updated_ids = updated_ids.dup
      block_size = 1000
      bulk_records = []

      existing_digests = SeedRecord.where(seed_table_id: seed_table.id,
                                          record_id: updated_ids).index_by(&:record_id)
      counter = 0
      callbacks[:before_updating_digests].call(counter, updated_ids.size)
      while tmp_updated_ids.present?
        callbacks[:before_updating_a_part_of_digests].call(counter, updated_ids.size)
        updating_records = []
        targets = tmp_updated_ids.slice!(0, block_size)
        targets.each do |id|
          seed_record = existing_digests[id]
          if seed_record
            seed_record.digest = digests[id]
            updating_records << seed_record
          else
            bulk_records << SeedRecord.new(seed_table_id: seed_table.id,
                                           record_id:     id,
                                           digest:        digests[id])
          end
        end

        bulk_update_digests(updating_records)
        counter += targets.size
        callbacks[:after_updating_a_part_of_digests].call(counter, updated_ids.size)
      end
      callbacks[:after_updating_digests].call(counter, updated_ids.size)

      counter = 0
      callbacks[:before_making_bulk_digest_records].call(0, inserted_ids.size)
      inserted_ids.each do |id|
        if counter % block_size == 0
          callbacks[:before_making_a_part_of_bulk_digest_records].call(counter, inserted_ids.size)
        end

        bulk_records << SeedRecord.new(seed_table_id: seed_table.id,
                                       record_id:     id,
                                       digest:        digests[id])
        counter += 1
        if counter % block_size == 0
          callbacks[:after_making_a_part_of_bulk_digest_records].call(counter, inserted_ids.size)
        end
      end
      callbacks[:after_making_bulk_digest_records].call(inserted_ids.size, inserted_ids.size)

      bulk_size = bulk_records.size
      counter = 0
      callbacks[:before_inserting_digests].call(counter, bulk_size)
      while bulk_records.present?
        callbacks[:before_inserting_a_part_of_digests].call(counter, bulk_size)
        targets = bulk_records.slice!(0, block_size)
        SeedRecord.import(targets)
        counter += targets.size
        callbacks[:after_inserting_a_part_of_digests].call(counter, bulk_size)
      end
      callbacks[:after_inserting_digests].call(counter, bulk_size)
    end

    def after_seed_express_validation(args)
      return false unless klass.respond_to?(:after_seed_express_validation)

      errors, = klass.after_seed_express_validation(args)
      error = false
      if errors.present?
        STDOUT.puts
        STDOUT.puts errors.pretty_inspect
        error = true
      end

      return error
    end

    def self.table_to_klasses
      return @@table_to_klasses if @@table_to_klasses

      # Enables full of models
      Find.find("#{Rails.root}/app/models") { |f| require f if /\.rb$/ === f }

      table_to_klasses = ActiveRecord::Base.subclasses.
        select { |klass| klass.respond_to?(:table_name) }.
        flat_map { |klass| [klass.table_name.to_sym, klass] }
      @@table_to_klasses = Hash[*table_to_klasses]
    end

    private

    def get_errors(errors)
      ar_v = ActiveRecord::VERSION
      if ([ar_v::MAJOR, ar_v::MINOR] <=> [3, 2]) < 0
        # for older than ActiveRecord 3.2
        errors
      else
        # for equal or newer than ActiveRecord 3.2
        errors.messages
      end
    end

    def update_parent_digest_to_validate(args)
      return unless self.parent_validation
      parent_table = self.parent_validation
      parent_id_column = (parent_table.to_s.singularize + "_id").to_sym

      parent_ids = klass.where(:id => args[:inserted_ids] + args[:updated_ids]).
        select(parent_id_column).group(parent_id_column).map(&parent_id_column)

      SeedTable.get_record(parent_table).disable_record_cache(parent_ids)
    end

    def bulk_update_digests(records)
      return if records.empty?

      ids = records.map(&:id).join(',')
      digests = records.map { |v| "'#{v.digest}'"  }.join(',')
      updated_at = "'" + Time.zone.now.utc.strftime('%Y-%m-%dT%H:%M:%S') + "'"

      sql = <<-"EOF"
      UPDATE seed_records
      SET
        updated_at = #{updated_at},
        digest = ELT(FIELD(id, #{ids}), #{digests})
      WHERE
        id IN (#{ids})
    EOF

      ActiveRecord::Base.connection.execute(sql)
    end
  end
end
