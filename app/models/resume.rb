# == Schema Information
#
# Table name: resumes
#
#  id                  :integer          not null, primary key
#  overall_gpa         :decimal(, )
#  major_gpa           :decimal(, )
#  resume_text         :text
#  graduation_year     :integer
#  graduation_semester :string(255)
#  file                :string(255)
#  person_id           :integer
#  created_at          :datetime
#  updated_at          :datetime
#  included            :boolean          default(TRUE), not null
#

class Resume < ActiveRecord::Base
  belongs_to :person

  validates :overall_gpa, numericality: true
#  validates :major_gpa,
  validates :resume_text, presence: true
  validates :graduation_year, numericality: true
  validates :graduation_semester, presence: true
  validates :file, presence: true
  validates :included, inclusion: [true,false]

  after_create :validate_pdf
  before_destroy :delete_file


  default_scope -> { order('resumes.created_at DESC') }
  # so we can just pick out the 'first' of the resumes to get the most recent

  scope :since, lambda { |date| where(['resumes.created_at >= ?', date]) }

  scope :approved, lambda { where(included: true) }  # 'included' is reserved
  scope :excluded, lambda { where(included: false) }

  def delete_file

    begin
      File.delete(self[:file])
    rescue
      # Should log an error here
    end
  end

  def is_pdf?
    !!(`file -b #{self.file}` =~ /\APDF/)
  end


protected

  def validate
    if overall_gpa.nil? || overall_gpa > 4 || overall_gpa < 0
      errors.add :overall_gpa, "should be between 0.00 and 4.00 (inclusive)"
    end
    if (not major_gpa.nil?) && (major_gpa > 4 || major_gpa < 0)
      errors.add :major_gpa,
                 "if provided, should be between 0.00 and 4.00 (inclusive)"
    end
    if graduation_year.nil? ||
       graduation_year < 1915 || graduation_year > 2037
      errors.add :graduation_year, "should be between 1915 and 2037"
    end
    # should come back and make sure we have a "valid" pdf
    # should come back here and add a better test to make sure file structure
    # of the pdf is valid (so resume book generation doesn't fail)
  end

  # Set {included} based on whether this file is a pdf
  def validate_pdf
    # TODO use ruby libs
    begin
      self.update_attribute :included, self.is_pdf?
    rescue
      # TODO tell somebody
    end
  end

end
