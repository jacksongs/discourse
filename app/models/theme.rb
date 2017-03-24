require_dependency 'distributed_cache'
require_dependency 'stylesheet/compiler'
require_dependency 'stylesheet/manager'

class Theme < ActiveRecord::Base

  belongs_to :color_scheme

  def child_themes
    return @child_themes if @child_themes
    @child_themes = []
    return [] unless id

    uniq = Set.new

    iterations = 0
    added = [id]
    while added.length > 0 && iterations < 5
      themes = Theme.where('id in (SELECT child_theme_id
                                  FROM child_themes
                                  WHERE parent_theme_id in (?))', added).to_a

      added = []
      themes.each do |theme|
        next if uniq.include? theme.id
        next if theme.id == id
        added << theme.id
        @child_themes << theme
      end

      iterations += 1
    end

    @child_themes
  end

  ENABLED_KEY = '7e202ef2-56d7-47d5-98d8-a9c8d15e57dd'

  COMPILER_VERSION = 5

  @cache = DistributedCache.new('theme')

  def self.css_fields
    %w(mobile_scss desktop_scss embedded_scss)
  end

  def self.html_fields
    %w(body_tag head_tag header mobile_header footer mobile_footer)
  end

  before_create do
    self.key ||= SecureRandom.uuid
    true
  end

  def transpile(es6_source, version)
    template  = Tilt::ES6ModuleTranspilerTemplate.new {}
    wrapped = <<PLUGIN_API_JS
Discourse._registerPluginCode('#{version}', api => {
  #{es6_source}
});
PLUGIN_API_JS

    template.babel_transpile(wrapped)
  end

  def process_html(html)
    doc = Nokogiri::HTML.fragment(html)
    doc.css('script[type="text/x-handlebars"]').each do |node|
      name = node["name"] || node["data-template-name"] || "broken"
      is_raw = name =~ /\.raw$/
      if is_raw
        template = "require('discourse-common/lib/raw-handlebars').template(#{Barber::Precompiler.compile(node.inner_html)})"
        node.replace <<COMPILED
          <script>
            (function() {
              Discourse.RAW_TEMPLATES[#{name.sub(/\.raw$/, '').inspect}] = #{template};
            })();
          </script>
COMPILED
      else
        template = "Ember.HTMLBars.template(#{Barber::Ember::Precompiler.compile(node.inner_html)})"
        node.replace <<COMPILED
          <script>
            (function() {
              Ember.TEMPLATES[#{name.inspect}] = #{template};
            })();
          </script>
COMPILED
      end

    end

    doc.css('script[type="text/discourse-plugin"]').each do |node|
      if node['version'].present?
        begin
          code = transpile(node.inner_html, node['version'])
          node.replace("<script>#{code}</script>")
        rescue MiniRacer::RuntimeError => ex
          node.replace("<script type='text/discourse-js-error'>#{ex.message}</script>")
        end
      end
    end

    doc.to_s
  end


  attr_accessor :force_rebake

  before_save do
    Theme.html_fields.each do |html_attr|
      if force_rebake || self.send("#{html_attr}_changed?")
        self.send("#{html_attr}_baked=", process_html(resolve_attr(html_attr)))
      end
    end
  end

  def resolve_attr(attribute)
    resolved = [send(attribute)]
    child_themes.each do |theme|
      resolved << theme.send(attribute)
    end
    resolved.map!{|x| x.blank? ? nil : x}.compact.join("\n")
  end

  def any_stylesheet_changed?
    Theme.css_fields.each do |fieldname|
      return true if self.send("#{fieldname}_changed?")
    end
    false
  end

  after_save do
    remove_from_cache!
    if any_stylesheet_changed?
      Stylesheet::Manager.clear_theme_cache!
      [:dektop_theme, :embedded_theme, :mobile_theme].each do |theme|
        # Stylesheet::Manager.compile(theme, theme_id: self.id)
      end
    end
    MessageBus.publish "/header-change/#{key}", header if header_changed?
    MessageBus.publish "/footer-change/#{key}", footer if footer_changed?
  end

  after_destroy do
    remove_from_cache!
  end

  def self.enabled_key
    ENABLED_KEY.dup << RailsMultisite::ConnectionManagement.current_db
  end

  def self.field_for_target(target=nil)
    target ||= :desktop

    case target.to_sym
      when :mobile then :mobile_stylesheet
      when :desktop then :stylesheet
      when :embedded then :embedded_css
    end
  end

  def self.baked_for_target(target=nil)
    "#{field_for_target(target)}_baked".to_sym
  end

  %i{header top footer head_tag body_tag}.each do |name|
    define_singleton_method("custom_#{name}") do |preview_style=nil, target=:desktop|
      preview_style ||= ENABLED_KEY
      lookup_field(preview_style, target, name)
    end
  end

  def self.lookup_field(key, target, field)
    return if key.blank?

    cache_key = "#{key}:#{target}:#{field}:#{COMPILER_VERSION}"

    lookup = @cache[cache_key]
    return lookup.html_safe if lookup

    styles = [find_by(key: key)].compact

    val = if styles.present?
      styles.map do |style|
        lookup = target == :mobile ? "mobile_#{field}" : field
        if html_fields.include?(lookup.to_s)
          style.ensure_baked!(lookup)
          style.send("#{lookup}_baked")
        else
          style.send(lookup)
        end
      end.compact.join("\n")
    end

    (@cache[cache_key] = val || "").html_safe
  end

  def self.remove_from_cache!(key, broadcast = true)
    MessageBus.publish('/site_customization', key: key) if broadcast
    clear_cache!
  end

  def self.clear_cache!
    @cache.clear
  end

  def ensure_baked!(field)

    # If the version number changes, clear out all the baked fields
    if compiler_version != COMPILER_VERSION
      updates = { compiler_version: COMPILER_VERSION }
      Theme.html_fields.each do |f|
        updates["#{f}_baked".to_sym] = nil
      end

      update_columns(updates)
    end

    baked = send("#{field}_baked")
    if baked.blank?
      if val = resolve_attr(field)
        val = process_html(val) rescue ""
        self.update_columns("#{field}_baked" => val)
      end
    end
  end

  def remove_from_cache!
    self.class.remove_from_cache!(self.class.enabled_key)
    self.class.remove_from_cache!(key)
  end

  def add_child_theme!(theme)
    ChildTheme.create!(parent_theme_id: id, child_theme_id: theme.id)
    @child_themes = nil
    self.force_rebake = true
    save!
    self.force_rebake = false
    remove_from_cache!
    Theme.clear_cache!
  end
end

# == Schema Information
#
# Table name: themes
#
#  id                  :integer          not null, primary key
#  name                :string           not null
#  desktop_scss        :text
#  header              :text
#  user_id             :integer          not null
#  key                 :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  mobile_scss         :text
#  mobile_header       :text
#  footer              :text
#  mobile_footer       :text
#  head_tag            :text
#  body_tag            :text
#  top                 :text
#  mobile_top          :text
#  embedded_scss       :text
#  head_tag_baked      :text
#  body_tag_baked      :text
#  header_baked        :text
#  mobile_header_baked :text
#  footer_baked        :text
#  mobile_footer_baked :text
#  compiler_version    :integer          default(0), not null
#  user_selectable     :boolean          default(FALSE), not null
#  hidden              :boolean          default(FALSE), not null
#  color_scheme_id     :integer
#  common_scss         :text
#
# Indexes
#
#  index_themes_on_key  (key)
#
