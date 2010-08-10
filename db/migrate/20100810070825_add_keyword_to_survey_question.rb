class AddKeywordToSurveyQuestion < ActiveRecord::Migration
  def self.up
    add_column :survey_questions, :keyword, :integer, :default => 0
  end

  def self.down
    add_column :survey_questions, :keyword
  end
end
