module User::Searcher
  extend ActiveSupport::Concern

  included do
    # Nothing writes these any more; kept so the rows still get cleaned up.
    has_many :search_queries, class_name: "Search::Query", dependent: :destroy
  end

  HIGHLIGHT_OPENING_MARK = "<mark class=\"circled-text\"><span></span>"
  HIGHLIGHT_CLOSING_MARK = "</mark>"
  HIGHLIGHT_MARKERS = [ HIGHLIGHT_OPENING_MARK, HIGHLIGHT_CLOSING_MARK ].freeze

  # Always a lazy relation, so callers can page it. An unusable query filters to no board.
  def search(terms)
    build_search_relation(terms)
      .highlight(
        title: { markers: HIGHLIGHT_MARKERS },
        content: { markers: HIGHLIGHT_MARKERS, snippet: { words: 20 } }
      )
      .sort(created_at: :desc)
  end

  # limit(nil) because callers paginate this themselves: Card.mentioning strips
  # :select and :order before merging, but not the configured default :limit.
  def search_relation(terms)
    build_search_relation(terms).limit(nil).to_native_query
  end

  private
    def build_search_relation(terms)
      query = Search::Query.wrap(terms)
      boards = query.valid? ? board_ids : []

      if query.cjk?
        substring_search_relation(query, boards)
      else
        full_text_search_relation(query, boards)
      end
    end

    def full_text_search_relation(query, boards)
      ActiveSearch.index(:searchable)
        .search(query.to_s)
        .filter(account_id: account_id, board_id: boards)
    end

    # Filter-only: FTS5 porter and MySQL FULLTEXT drop CJK tokens, so MATCH
    # cannot find them. LIKE against the stored title/content can, and a blank
    # search query keeps highlight() / snippet() from running against no MATCH.
    def substring_search_relation(query, boards)
      ActiveSearch.index(:searchable)
        .filter(account_id: account_id, board_id: boards, searchable_id: substring_searchable_ids(query, boards))
    end

    def substring_searchable_ids(query, boards)
      if boards.empty?
        []
      else
        model = search_record_model
        scope = substring_text_scope(model.where(account_id: account_id, board_id: boards), model)

        substring_terms(query).each do |term|
          pattern = "%#{model.sanitize_sql_like(term)}%"
          title, content = substring_text_columns(model)
          scope = scope.where("#{title} LIKE ? ESCAPE ? OR #{content} LIKE ? ESCAPE ?", pattern, "\\", pattern, "\\")
        end

        scope.distinct.limit(ActiveSearch.index(:searchable).store.capabilities.max_result_window).pluck(:searchable_id)
      end
    end

    def search_record_model
      index = ActiveSearch.index(:searchable)
      index.store.send(:model_for, index, routing: account_id)
    end

    def substring_text_scope(scope, model)
      if sqlite_search?
        fts = "#{model.table_name}_fts"
        scope.joins("INNER JOIN #{fts} ON #{fts}.rowid = #{model.table_name}.rowid")
      else
        scope
      end
    end

    def substring_terms(query)
      query.to_s.gsub("\"", " ").split(/\s+/).reject(&:blank?)
    end

    def substring_text_columns(model)
      if sqlite_search?
        fts = "#{model.table_name}_fts"
        [ "#{fts}.title", "#{fts}.content" ]
      else
        table = model.quoted_table_name
        [ "#{table}.#{model.connection.quote_column_name("title")}",
          "#{table}.#{model.connection.quote_column_name("content")}" ]
      end
    end

    def sqlite_search?
      Search::Record.connection.adapter_name == "SQLite"
    end
end
