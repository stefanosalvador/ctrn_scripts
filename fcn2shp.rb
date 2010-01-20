#! /usr/bin/ruby

require 'gdal/ogr'

module CtrnFvg

  class Global
    @@useWGS84 = false
    @@tollerance = 1 # meters
    @@folder = ""
    @@serialization_threshold = 2000
    @@trasformer = nil
    @@simplify = true

    def self.useWGS84
      return @@useWGS84
    end

    def self.useWGS84=(u)
      @@useWGS84 = u
    end

    def self.simplify
      return @@simplify
    end

    def self.simplify=(u)
      @@simplify = u
    end

    def self.folder
      return @@folder
    end

    def self.folder=(u)
      @@folder = u
    end

    def self.serialization_threshold
      return @@serialization_threshold
    end

    def self.serialization_threshold=(u)
      @@serialization_threshold = u
    end

    def self.tollerance
      return @@tollerance
    end

    def self.get_trasformer
      if(@@trasformer.nil?)
        sp_gb = Gdal::Osr::SpatialReference.new()
	# Following transformation parameters are produced by Alberto Beinat (Univaersity of Udine), which I thank
        sp_gb.import_from_proj4("+proj=tmerc +lat_0=0 +lon_0=15 +k=0.999600 +x_0=2520000 +y_0=0 +ellps=intl +units=m +towgs84=-128.6633,-30.2694,-6.12,-1.05572,-2.6951,-2.28808,-16.9352")
        sp_wgs84 = Gdal::Osr::SpatialReference.new()
        sp_wgs84.import_from_epsg(4326)
        @@trasformer = Gdal::Osr::CoordinateTransformation.new(sp_gb, sp_wgs84)
      end
      return @@trasformer
    end

    def self.tollerance=(u)
      @@tollerance = u
    end
  end
  ############################
  # Layer class
  ############################
  class Layer
    attr :name, true
    attr :ogr_type, true
    
    def initialize(name)
      self.name = name
      @features = []
      @attributes = {}
      @border_points = {}
      @total_features = 0
      @ogr_attributes = []
    end

    def summary
      p "layer #{name} contains #{@total_features} features" + (CtrnFvg::Global.simplify ? " and has #{@border_points.size} points not simplified" : "")
    end

    def add_feature(obj)
      return if obj.cancelled?

      if(Global.simplify)
        # 1. extract each border point of this feature
        current_border_points = []
        obj.points.each do |point|
          current_border_points << point if(point.border)
        end

        # 2. find all feature involded
        features_involved = {} # key is the feature, value are all border points involded
        cbp_to_del = []
        bp_to_del = []
        current_border_points.each do |point|
          @border_points.each do |bp, feature|
            if(point == bp || point.near?(bp))
              cbp_to_del << point
              bp_to_del << bp
              if(features_involved.has_key?(feature))
                features_involved[feature] << point
              else
                features_involved[feature] = [point]
              end
            end
          end
        end
        current_border_points = current_border_points - cbp_to_del
        @border_points.reject! {|p, f| bp_to_del.include?(p)}

        # 3. add border points not found
        current_border_points.each do |p|
          @border_points[p] = obj
        end

        # 4. merge all
        features_involved.each do |feature, points|
          begin
            obj.merge(feature, points)
            @features.delete(feature)
            @total_features = @total_features - 1
          rescue Exception => te
            obj.set_attribute(:simplified, 0)
          end
        end
      end

      # 5. add new feature
      @features << obj
      @total_features = @total_features + 1

      # 6. serialize if needed
      if(@features.size > Global.serialization_threshold)
        print "."
        STDOUT.flush
        to_shape(false)
      end
    end

    def to_shape(all = true)
      open_ogr_layer
      features_to_be_removed = []
      @features.each do |feature|
        if(Global.simplify)
          to_be_simplified = @border_points.values.include?(feature)
          next if(to_be_simplified && all == false)
          feature.set_attribute(:simplified, to_be_simplified ? 0 : 1) if (feature.get_attribute(:simplified) == 2)
        end
        create_missing_attributes(feature)
        ogr_feature = Gdal::Ogr::Feature.new(@ogr_layer.get_layer_defn)
        ogr_feature.set_geometry(feature.ogr_geom)
        feature.attributes.each do |name, value|
          ogr_feature.set_field(name.to_s, value)
        end
        @ogr_layer.create_feature(ogr_feature)
        features_to_be_removed << feature
      end
      @features = @features - features_to_be_removed
      close_ogr_layer
    end

    private
    def create_missing_attributes(feature)
      feature.attributes.each do |name, value|
        unless @ogr_attributes.include?(name)
          field_defn = if(value.is_a?(Fixnum))
            Gdal::Ogr::FieldDefn.new(name.to_s, Gdal::Ogr::OFTINTEGER)
          else
            Gdal::Ogr::FieldDefn.new(name.to_s, Gdal::Ogr::OFTSTRING)
          end
          @ogr_layer.create_field(field_defn)
          @ogr_attributes << name
        end
      end
    end

    def open_ogr_layer
      folder = Global.folder
      @data_source = Gdal::Ogr.open(File.join(folder, "#{name}.shp"), 1)
      if(@data_source.nil?)
        driver = Gdal::Ogr.get_driver_by_name('ESRI Shapefile')
        @data_source = driver.create_data_source(folder)
        srs = Gdal::Osr::SpatialReference.new()
        # 4326 - WGS84 geographic, 3004 - Gauss Boaga projected
        srs.import_from_epsg(Global.useWGS84 ? 4326 : 3004)
        @ogr_layer = @data_source.create_layer(name, srs, ogr_type)
      else
        @ogr_layer = @data_source.get_layer(0)
      end
    end

    def close_ogr_layer
      #Gdal::Ogr::DataSource::destroy_data_source(@data_source)
      @data_source = nil
      @ogr_layer = nil
      GC::start
    end
  end

  ############################
  # Map class
  ############################
  class Map
    
    def initialize
      @layers = {}
    end

    def summary
      p "map contains #{@layers.size} layers"
      @layers.each do |k, v|
        v.summary
      end
    end

    def add_layer(name)
      @layers[name] = Layer.new(name)
      return @layers[name]
    end

    def get_layer(feature)
      unless(@layers.has_key?(feature.name))
        layer = add_layer(feature.name)
        layer.ogr_type = feature.ogr_type
      end
      return @layers[feature.name]
    end

    def add_feature(obj)
      get_layer(obj).add_feature(obj)
    end

    def to_shape(folder)
      @layers.each do |name, layer|
        layer.to_shape(folder)
      end
    end
  end

  module Constants
    module FeatureType
      LINE =  'L'
      POINT = 'P'
      AREA =  'A'
      TEXT =  'T'
    end

    module Visibility
      VISIBLE = 'V'
      HIDDEN  = 'I'
      CUT     = 'T'
    end
  end

  ############################
  # Point class
  ############################
  class Point
    attr :visibility, true  # V, I, T
    attr :border, true      # true / false
    attr :edit_type, true   # R, C, M, E
    attr :position, true    # 1, 2, 3

    def initialize(x,y,z)
      z = 0 if z == '999999'
      @coordinates = [
        (x.to_i + 200000000) / 100.0,
        (y.to_i + 500000000) / 100.0,
        z.to_i / 100.0
      ]
      @wgs84_coordinates = Global.get_trasformer.transform_point(*@coordinates) if(Global.useWGS84)
    end

    def coordinates
       return @coordinates
    end

    def wgs84_coordinates
       return @wgs84_coordinates
    end

    def == (point)
      return (@coordinates[0] == point.coordinates[0]) && (@coordinates[1] == point.coordinates[1])
    end

    def near? (point)
      return (@coordinates[0] - point.coordinates[0]).abs < Global.tollerance &&
             (@coordinates[1] - point.coordinates[1]).abs < Global.tollerance
    end

    def first?
       return position == "1"
    end

    def last?
       return position == "3"
    end

  end

  ############################
  # Feature class
  ############################
  class Feature

    attr :section,    true  # Class of CTRN
    attr :type,       true  # P, T, L, A
    attr :layer,      true  # 
    attr :revision,   true  # 000 or the new revision of the data

    def initialize
      @closed = false
      @points = []
      @attributes = {:source => 'Regione_Friuli-Venezia-Giulia_17620_2.100_17576', :simplified => 2}
    end

    def add_point(point)
      @points << point
    end

    def remove_point(point)
      @points.delete(point)
    end

    def merge(feature, points)
      # use OGR to do this, slow but tested
      @ogr_geom = ogr_geom.union(feature.ogr_geom)
    end

    def points
      return @points
    end

    def set_attribute(name, value)
      @attributes[name] = value
    end
    
    def get_attribute(name)
      return @attributes[name]
    end
    
    def has_attribute?(name)
      @attributes.has_key?(name)
    end
    
    def attributes
      return @attributes
    end
    
    def ogr_geom
      if(@ogr_geom.nil?)
        @ogr_geom = Gdal::Ogr.create_geometry_from_wkt(to_wkt)
      end
      return @ogr_geom
    end

    def ogr_type
      case type
        when Constants::FeatureType::POINT, Constants::FeatureType::TEXT:
          Gdal::Ogr::WKBPOINT25D
        when Constants::FeatureType::LINE:
          Gdal::Ogr::WKBLINESTRING25D
        when Constants::FeatureType::AREA:
          Gdal::Ogr::WKBPOLYGON25D
      end
    end
    
    def to_wkt
      case type
        when Constants::FeatureType::POINT, Constants::FeatureType::TEXT:
          return "POINT(%.11f %.11f %.11f)" %(Global.useWGS84 ? @points[0].wgs84_coordinates : @points[0].coordinates)
        when Constants::FeatureType::LINE:
          return "LINESTRING(#{(@points.map {|p| "%.11f %.11f %.11f" %(Global.useWGS84 ? p.wgs84_coordinates : p.coordinates) }).join(", ")})"
        when Constants::FeatureType::AREA:
          return "POLYGON((#{(@points.map {|p| "%.11f %.11f %.11f" %(Global.useWGS84 ? p.wgs84_coordinates : p.coordinates) }).join(", ")}))"
      end
    end

    def name
      return section + type + layer
    end

    def code
      return section + type + revision + layer
    end

    def cancelled?
      return revision[2..2] == 'C'
    end

    def empty?
      return @points.empty?
    end

    def point?
      return type == Constants::FeatureType::POINT
    end

    def closed?
      return @closed
    end

    def close
      set_attribute(:code, name)
      set_attribute(:revision, revision)
      @closed = true
    end

    def line?
      return type == Constants::FeatureType::LINE
    end

    def area?
      return type == Constants::FeatureType::AREA
    end

    def text?
      return type == Constants::FeatureType::TEXT
    end
  end

  ############################
  # DatParser class
  ############################
  class DatParser

    def initialize(filename)
      @filename = filename
      @file = File.new(filename)
      @text_counter = 0
    end

    def parse
      map = Map.new
      current_feature = nil
      while(line = @file.gets)
        current_feature = parse_line(current_feature, line)
        map.add_feature(current_feature) if current_feature.closed?
      end
      return map
    end

    def parse_line(feature, line)
      return feature if(line =~ /^99999/)
      #4A000AFV 34624047 16490192 168652 21 IR
      #1234567fbEEEEEEEEbNNNNNNNNbQQQQQQbccbkw
      #012345678901234567890123456789012345678
      #          1         2         3
      if(feature.nil? || feature.closed?)
        feature = Feature.new
        feature.section = line[0..0]
        feature.type = line[1..1]
        feature.revision = line[2..4]
        feature.layer = line[5..6]
      elsif( ! feature.text? && feature.name != (line[0..1] + line[5..6]))
        raise "Parser error"
      end

      if feature.text? && @text_counter > 0
        if(@text_counter == 1)
          feature.set_attribute(:position, line[0..0])
          feature.set_attribute(:num_char, line[2..5].to_i)
          feature.set_attribute(:box_x, line[7..11].to_i)
          feature.set_attribute(:box_y, line[13..17].to_i)
          feature.set_attribute(:angle, line[19..24].to_i)
          @text_counter = @text_counter.next
        elsif(@text_counter == 2)
          feature.set_attribute(:content, line.strip)
          @text_counter = 0
          feature.close
        end
        return feature
      else
        case line[34..35]
          when '11':
            raise "Parser error" unless feature.point?
            feature.close
          when '21','31','41':
            raise "Parser error" if feature.point? 
          when '22','32','42':
            raise "Parser error" if (feature.point? || feature.empty?)
          when '23','33','43':
            raise "Parser error" if (feature.point? || feature.empty?)
            feature.close
          when '81':
            @text_counter = @text_counter.next
            raise "Parser error" unless feature.text?
          else
            raise "Parser error"
        end
      end
      point = Point.new(line[9..16], line[18..25], line[27..32] )
      point.position = line[35..35]
      point.visibility = line[7..7]
      point.border = (line[37..37] == 'B')
      point.edit_type = line[38..38]
      feature.add_point(point)
      return feature
    end
  end
end

CtrnFvg::Global.useWGS84 = ARGV.size > 2 && ARGV[2] == 'true'
CtrnFvg::Global.folder = ARGV[1]
CtrnFvg::Global.simplify = ARGV.size > 3 && ARGV[3] == 'true'
dp = CtrnFvg::DatParser.new(ARGV[0])
map = dp.parse
p ""
map.summary
map.to_shape(true)

