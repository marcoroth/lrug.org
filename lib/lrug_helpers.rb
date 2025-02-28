require 'nokogiri'

module LRUGHelpers
  def generate_description(for_page = current_page)
    extracted = for_page.data[:description] || _extract_description_from_page(for_page)
    extracted.presence || "An exciting page about #{page_title(for_page)} as it relates to the London Ruby User Group."
  end

  private
  def _extract_description_from_page(for_page)
    rendered = for_page.render layout: false

    doc = Nokogiri::HTML::DocumentFragment.parse(rendered)
    doc.css('p').first.text
  rescue
    ''
  end
  public

  def page_title(for_page = current_page)
    yield_content(:title) || for_page.data.title
  end

  def rss_path(for_page = current_page)
    "/rss/#{yield_content :rss_path}"
  end

  def show_sponsors(for_page = current_page)
    partial "sponsors", locals: { for_page: for_page }
  end

  def link_to_most_recent(category)
    meeting = most_recent(category)
    link_to meeting.data.title, meeting
  end

  def most_recent(category)
    pages_in_category(category).first
  end

  def pages_in_category(category)
    sitemap
      .resources
      .select { |page| page_has_data?(page, status: 'Published', category: category) }
      .sort_by { |page| page.data.published_at }
      .reverse
  end

  def meeting_pages
    pages_in_category 'meeting'
  end

  def book_reviews
    pages_in_category 'book-review'
  end

  def podcast_episodes
    pages_in_category 'podcast'
  end

  def nights_episodes
    pages_in_category 'nights'
  end

  def page_has_data?(page, args)
    args.all? do |key, value|
      page.data[key.to_s] == value
    end
  end

  def content_part_exists?(part_name, page, inherit: false)
    find_page_part(part_name, page, inherit: inherit).present?
  end

  def render_content_part(part_name, page, inherit: false)
    part = find_page_part(part_name, page, inherit: inherit)
    if part
      if part['render_as'].present?
        renderers = part['render_as'].split('.').reverse.reject { |renderer| renderer.blank? }
        # Add all the render_as extensions to the fake path
        pathname = "#{page.path}#content-part-#{part_name}#{part['render_as']}"
        # Always push things through erb even if it's not an explicit render_as
        unless renderers.first == 'erb'
          renderers.prepend('erb')
          pathname.concat('.erb')
        end
        renderers.inject(part['content']) do |body, renderer|
          current_path = pathname.dup
          # strip off the current renderer for the next iteration of the loop
          pathname.gsub!(/\.#{renderer}$/, '')
          inline_content_render(body, current_path, locals: {page: page})
        end
      else
        part['content']
      end
    else
      ''
    end
  end

  def month_of_meeting(meeting)
    match = meeting.data.title.match(/(January|February|March|April|May|June|July|August|September|October|November|December)/i)
    if match
      match[1]
    else
      meeting.data.title
    end
  end

  def hosting_sponsors(most_recent_first: false, without: [])
    sponsor_list('hosted_by', most_recent_first: most_recent_first, without: without)
  end

  def meeting_sponsors(most_recent_first: false, without: [])
    sponsor_list('sponsors', most_recent_first: most_recent_first, without: without)
  end

  private
  SponsorData = Struct.new(:name, :occurrences, :most_recent, keyword_init: true) do
    def <=>(other)
      return nil unless other.respond_to?(:occurrences) && other.respond_to?(:most_recent)

      case other.occurrences
      when self.occurrences
        self.most_recent <=> other.most_recent
      else
        self.occurrences <=> other.occurrences
      end
    end
  end

  def sponsor_list(data_key, most_recent_first: , without: )
    sponsors = meeting_pages.
      select { |meeting_page| meeting_page.data.key? data_key }.
      map { |meeting_page| [meeting_page.data[data_key].first, meeting_page.data.meeting_date] }.
      group_by { |(sponsor, _date)| sponsor.name }.
      map do |sponsor_name, occurrences|
        SponsorData.new(
          name: sponsor_name,
          occurrences: occurrences.size,
          most_recent: occurrences.map { |(_sponsor, date)| date }.sort.last
        )
      end.
      reject { |sponsor_data| without.include? sponsor_data.name }.
      sort.
      reverse
    return sponsors unless most_recent_first

    most_recent = sponsors.sort_by { |sponsor_data| sponsor_data.most_recent }.last
    return [most_recent] + (sponsors - [most_recent])
  end
  public

  def sponsor_logo(sponsor_name, size: 'sidebar')
    sponsor = data.sponsors.detect { |sponsor| sponsor.name == sponsor_name }
    if sponsor
      link_text =
        if sponsor.logo? && sponsor.logo[size]
          %{<img src="#{sponsor.logo[size].url}" width="#{sponsor.logo[size].width}" height="#{sponsor.logo[size].height}" alt="#{sponsor.name}" title="#{sponsor.name} Logo" loading="lazy"/>}
        else
          sponsor.name
        end
      link_to link_text, sponsor.url
    end
  end

  private
  def find_page_part(part_name, page, inherit: false)
    if page.data.parts? && page.data.parts.has_key?(part_name)
      page.data.parts[part_name]
    elsif inherit && page.parent.present?
      find_page_part(part_name, page.parent, inherit: inherit)
    else
      nil
    end
  end

  public
  def date_format(date, format)
    date.strftime(format) unless date.nil?
  end

  def rfc_1123_date(date)
    date.rfc2822 unless date.nil?
  end

  def render_markdown(md)
    inline_content_render(md, 'inline-markdown-fragment.md')
  end

  def meeting_calendar_link
    %{<span class="calendar-link"><a href="/meetings.ics"><img src="https://assets.lrug.org/images/calendar_down.gif" alt="Calendar subscription" loading="lazy"> Meeting Calendar</a></span>}
  end

  def indent_xml(indent, xml_string)
    xml_string.gsub(/^/,' ' * indent)
  end

  def format_redirect_from_regex(redirect_from)
    regex = redirect_from.dup
    regex.prepend '^' unless redirect_from.start_with? '^'
    regex.concat '($|/)' unless redirect_from.end_with? '$'
    regex
  end

  def thanks_needed?(page)
    has_sponsors?(page) || has_host?(page)
  end

  def has_sponsors?(page)
    content_part_exists?('sponsors', page) || page.data.has_key?('sponsors')
  end

  def has_host?(page)
    content_part_exists?('hosted_by', page) || page.data.has_key?('hosted_by')
  end

  def events_calendar(site_url:)
    calendar = Icalendar::Calendar.new
    calendar.timezone do |timezone|
      timezone.tzid = 'Europe/London'
    end
    zone = ActiveSupport::TimeZone['Europe/London']

    all_meetings = meeting_pages

    upcoming = all_meetings.take_while {|page| page.metadata[:page][:meeting_date] >= Date.today}
    next_12 = all_meetings.drop(upcoming.length).take(12)

    (upcoming + next_12).each do |page|
      url = URI.join(site_url, page.url)
      date = page.metadata[:page][:meeting_date]
      title = page.metadata[:page][:title]
      hosts  = page.metadata[:page][:hosted_by]

      calendar.event do |event|
        event.uid = "lrug-monthly-#{date.strftime('%Y-%m')}"
        event.dtstart = date.in_time_zone(zone).change(hour:18)
        event.dtend   = date.in_time_zone(zone).change(hour:20)
        event.summary   = "London Ruby User Group - #{title}"
        event.url         = URI.join(site_url, page.url)

        if hosts.present?
          hosted_by = "Hosted by: #{hosts.map {|h| h[:name]}.join(', ')}"
        end

        event.description = <<~DESC
        London Ruby User Group - #{title}

        #{hosted_by}
        DESC
      end
    end

    calendar
  end

  private
  def inline_content_render(content, fake_pathname, locals: {})
    # create a middleman filerenderer to do the work, the extension in
    # the last extension in the path tells it which template engine to use
    # and because it's a middleman object it'll make sure it's properly
    # configured via settings in config.rb, which us creating a Tilt
    # instance directly won't neccessarily do
    content_renderer = ::Middleman::FileRenderer.new(@app, fake_pathname)
    content_renderer.render(locals, {template_body: content, layout: false}, @app.template_context_class.new(@app, locals, {layout: false}))
  end
end
