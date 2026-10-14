class Search::Query < ApplicationRecord
  belongs_to :account, default: -> { user&.account || Current.account }
  belongs_to :user, optional: true

  validates :terms, presence: true
  before_validation :sanitize_terms

  delegate :to_s, to: :terms

  # Porter / MySQL FULLTEXT both treat these as separators, so a query that
  # contains any of them has to take the substring path in User::Searcher.
  CJK_CHAR = /\p{Han}|\p{Hiragana}|\p{Katakana}|\p{Hangul}/

  class << self
    def wrap(query)
      if query.is_a?(self)
        query
      else
        self.new(terms: query)
      end
    end
  end

  def cjk?
    terms.to_s.match?(CJK_CHAR)
  end

  private
    def sanitize_terms
      self.terms = sanitize(terms)
    end

    def sanitize(terms)
      if terms.present?
        terms = remove_unbalanced_quotes(self.terms)
        terms = quote_joined_words(terms)
        terms = remove_invalid_search_characters(terms)
        terms.presence
      else
        terms
      end
    end

    def remove_unbalanced_quotes(terms)
      if terms.count("\"").even?
        terms
      else
        terms.gsub("\"", " ")
      end
    end

    def quote_joined_words(terms)
      terms.gsub(/"[^"]*"|\w+(?:[^\w[:space:]\u200B"]+\w+)+/) { |match| match.start_with?("\"") ? match : "\"#{match}\"" }
    end

    # \w is ASCII. CJK letters have to be kept or a query like 商标 becomes
    # blank, fails validation, and User::Searcher filters to no board.
    def remove_invalid_search_characters(terms)
      terms.gsub(/[^\w\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}"]/, " ")
    end
end
