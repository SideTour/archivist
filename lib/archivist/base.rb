# Require sub-module's files
mods = File.join(File.dirname(__FILE__),"base","**","*.rb")
Dir.glob(mods).each do |mod|
  require mod
end

module Archivist
  module Base

    DEFAULT_OPTIONS = {:associate_with_original=>false,:allow_multiple_archives=>false}

    def self.included(base)
      base.extend ClassMethods
    end
    
    module ClassMethods
      def has_archive(options={})
        options = DEFAULT_OPTIONS.merge(options)
        options[:allow_multiple_archives] = true if options[:associate_with_original]
        
        class_eval <<-EOF
          alias_method :delete!, :delete
          
          class << self
            alias_method :delete_all!, :delete_all
          end
          
          def self.archive_indexes
            #{Array(options[:indexes]).collect{|i| i.to_s}.inspect}
          end

          def self.archive_options
            #{options.inspect}
          end
          
          def self.has_archive?
            true
          end
          
          def self.acts_as_archive?
            warn "DEPRECATION WARNING: #acts_as_archive is provided for compatibility with AAA and will be removed soon, please use has_archive?"
            has_archive?
          end

          class Archive < ActiveRecord::Base
            self.record_timestamps = false
            self.table_name = "archived_#{self.table_name}"
            #{build_serialization_strings(self.serialized_attributes)}
            #{build_belongs_to_association(options[:associate_with_original])}
            #{build_inclusion_strings(options[:included_modules])}
            include Archivist::ArchiveMethods
          end

          #{build_has_many_association(options[:associate_with_original])}
          
          #{build_copy_self_to_archive(options[:allow_multiple_archives])}
        EOF
        
        include InstanceMethods
        extend ClassExtensions
        include DB
      end

      def acts_as_archive(options={})
        has_archive(options)
      end

      def build_inclusion_strings(included_modules)
        modules = ""
        included_modules = [included_modules] unless included_modules.is_a?(Array)
        included_modules.each do |mod|
          modules << "include #{mod.to_s}\n"
        end
        return modules
      end
      
      def build_serialization_strings(serializde_attributes)
        serializations = ""
        self.serialized_attributes.each do |key,value|
          serializations << "serialize(:#{key},#{value.to_s})\n"
        end
        return serializations
      end
      
      def build_has_many_association(associate=false)
        associate ? "has_many :archived_#{self.table_name},:class_name=>'#{self.new.class.to_s}::Archive'" : ""
      end
      
      def build_belongs_to_association(associate=false)
        associate ? "belongs_to :#{self.table_name},:class_name=>'#{self.new.class.to_s}'" : ""
      end
      
      def build_copy_self_to_archive(allow_multiple=false)
        if allow_multiple #we put the original pk in the fk instead
          "def copy_self_to_archive
            self.class.transaction do
              attrs = self.attributes.merge(:deleted_at=>DateTime.now)
              archived = #{self.to_s}::Archive.new(attrs.reject{|k,v| k=='id'})
              archived.#{self.to_s.underscore}_id = attrs['id']
              #{yield_and_save}
            end
          end"
        else
          "def copy_self_to_archive
            self.class.transaction do #it would be really shitty for us to loose data in the middle of this
              attrs = self.attributes.merge(:deleted_at=>DateTime.now)
              archived = #{self.to_s}::Archive.new
              if archived.class.where(:id=>self.id).empty? #create a new one if necessary, else update
                archived.id = attrs[\"id\"]
                archived.attributes = attrs.reject{|k,v| k=='id'}
              else
                archived = archived.class.where(:id=>attrs[\"id\"]).first
                archived.update_attributes(attrs)
              end
              #{yield_and_save}
            end
          end"
        end
      end

      def yield_and_save
        "yield(archived) if block_given?
        archived.save"
      end
      
      private :build_inclusion_strings,:build_serialization_strings,
              :build_has_many_association,:build_belongs_to_association,
              :build_copy_self_to_archive,:yield_and_save
    end
    
    module InstanceMethods #these defs can't happen untill after we've aliased their respective originals

      def delete
        result = self.copy_self_to_archive unless new_record?
        self.delete! if result
        @destroyed = true
        freeze
      end
      
      def destroy
        _run_destroy_callbacks do
          self.delete
        end
      end
      
      def destroy!
        transaction do
          _run_destroy_callbacks do
            self.delete!
          end
        end
      end
    end

    module ClassExtensions #these can't get included in the class def until after all aliases are done
      def copy_to_archive(conditions,delete=true,&block)
        where = sanitize_sql(conditions)
        found = self.where(where)
        
        found.each do |m|
          result = m.copy_self_to_archive(&block)
          m.destroy! if delete && result
        end
      end
      
      def copy_from_archive(conditions,delete=true)
        where = sanitize_sql(conditions)
        where = where.gsub("#{table_name}","archived_#{table_name}") unless where.nil? || where =~ /archived/
        unless where == ""
          found = self::Archive.where(where)
        else
          found = self::Archive.all
        end

        found.each do |m|
          self.transaction do
            my_attribute_names = self.new.attribute_names
            #this should be Hash.select but 1.8.7 returns an array from select but a hash from reject... dumb
            attrs = m.attributes.reject{|k,v| !my_attribute_names.include?(k.to_s)} 

            if self.where(:id=>m.id).empty?
              new_m = self.create(attrs)
              connection.execute(%Q{UPDATE #{table_name} 
                                    SET #{self.primary_key} = #{m.id} 
                                    WHERE #{self.primary_key} = #{new_m.id}
                                   })
            else
              self.where(:id=>m.id).first.update_attributes(attrs)
            end
            m.destroy if delete  
          end
        end
      end

      def delete_all(conditions=nil)
        copy_to_archive(conditions)
      end

      def restore_all(conditions=nil)
        copy_from_archive(conditions)
      end
    end
  end
end
