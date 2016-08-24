module SeedExpress
  module ModelValidator
    def validation_which_not_null_without_default
      target_columns = self.class.not_null_without_default_columns
      target_columns.each do |column|
        next unless self[column].nil?
        self.errors[column] << "must be set"
      end
    end

    module ClassMethods
      extend Memoist

      def not_null_without_default_columns
        self.columns.select do |v|
          not_null_without_default_column?(v)
        end.map(&:name).map(&:to_sym)
      end

      def not_null_without_default_column?(column)
        !column.primary && !column.null && column.default.nil?
      end
    end

    class << self
      def included(klass)
        klass.extend ClassMethods
        klass.class_eval do
          validate :validation_which_not_null_without_default
        end
      end
    end
  end
end