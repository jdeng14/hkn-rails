class CoursesurveysController < ApplicationController
  include CoursesurveysHelper

  before_filter :show_searcharea
  before_filter :require_admin, :only => [:editrating, :updaterating, :editinstructor, :updateinstructor]

  begin # caching
    [:index, :instructors].each {|a| caches_action a, :layout => false}
    caches_action :klass, :cache_path => Proc.new {|c| klass_cache_path(c.params)}, :layout => false

    # Cache full/partial department lists
    caches_action :department, :layout => false, :cache_path => Proc.new {|c| "coursesurveys/department_#{c.params[:dept_abbr]}_#{c.params[:full_list].blank? ? 'recent' : 'full'}"}

    # Separate for admins
    #caches_action_for_admins([:instructor], :groups => %w(csec superusers))
  end
  cache_sweeper :instructor_sweeper

  def authorize_coursesurveys
    @current_user && (@auth['csec'] || @auth['superusers'])
  end
  
  def require_admin
    return if authorize_coursesurveys
    flash[:error] = "You must be an admin to do that."
    redirect_to coursesurveys_path
  end

  def index
  end

  def department
    params[:dept_abbr].downcase! if params[:dept_abbr]

    @department  = Department.find_by_nice_abbr(params[:dept_abbr])
    @prof_eff_q  = SurveyQuestion.find_by_keyword(:prof_eff)
    @lower_div   = []
    @upper_div   = []
    @grad        = []
    @full_list   = params[:full_list].present?

    # Error checking
    return redirect_to coursesurveys_search_path("#{params[:dept_abbr]} #{params[:short_name]}") unless @department

    #Course.find(:all, :conditions => {:department_id => @department.id}, :order => 'course_number, prefix, suffix').each do |course|
    # includes(:klasses => {:instructorships => :instructor}).
    Course.where(:department_id => @department.id).includes(:instructorships).ordered.each do |course|
      next if course.invalid?

      ratings = []

      # Find only the most recent course, optionally with a lower bound on semester
      first_klass = course.klasses
      first_klass = first_klass.where(:semester => Property.make_semester(:year=>4.years.ago.year)..Property.make_semester) unless @full_list
      first_klass = first_klass.find(:first, :include => {:instructorships => :instructor} )

      # Sometimes the latest klass is really old, and not included in these results
      next unless first_klass.present?

      # Find the average, or silently fail if something is missing
      # TODO: silent is bad
      #next unless avg_rating = course.survey_answers.collect(&:mean).average #.average(:mean)
      next unless avg_rating = course.average_rating.to_f

      # Generate row
      instructors = course.instructors.uniq[0..3]
      result = { :course      => course,
                 :instructors => instructors,
                 :mean        => avg_rating,
                 :klass       => first_klass  }

      # Append course to correct list
      case course.course_number.to_i
        when   0.. 99: @lower_div
        when 100..199: @upper_div
        else           @grad
      end << result
 end

  end

  def course
    @course = Course.find_by_short_name(params[:dept_abbr], params[:short_name])

    # Try searching if no course was found
    return redirect_to coursesurveys_search_path("#{params[:dept_abbr]} #{params[:short_name]}") unless @course

    # eager-load all necessary data. wasteful course reload, but can't get around the _short_name helper.
    @course = Course.find(@course.id, :include => [:klasses => {:instructorships => :instructor}])

    effective_q  = SurveyQuestion.find_by_keyword(:prof_eff)
    worthwhile_q = SurveyQuestion.find_by_keyword(:worthwhile)

    @results = []
    @overall = { :effectiveness  => {:max=>effective_q.max },
                 :worthwhile     => {:max=>worthwhile_q.max}
               }

    @course.klasses.each do |klass|
      result = { :klass         => klass,
                 :instructors   => klass.instructors,
                 :effectiveness => { },
                 :worthwhile    => { }
               }

      # Some heavier computations
      [ [:effectiveness, effective_q ],
        [:worthwhile,    worthwhile_q]
      ].each do |qname, q|
        result[qname][:score] = klass.survey_answers.where(:survey_question_id => q.id).average(:mean)
      end

      @results << result
    end # @course.klasses

    [ :effectiveness, :worthwhile ].each do |qname|
      @overall[qname][:score] = @results.collect{|r|r[qname][:score]}.sum / @results.size.to_f
    end

  end

  def klass
    @klass = params_to_klass(params)

    # Error checking
    if @klass.blank?
       flash[:notice] = "No class found for #{params[:semester].gsub('_',' ')}."
       return redirect_to coursesurveys_course_path(params[:dept_abbr], params[:short_name])
    end

    @instructors, @tas = [], []

    @klass.instructorships.each do |i|
      (i.ta ? @tas : @instructors) << { :instructor => i.instructor,
                                        :answers    => (i.instructor.private ?
                                                        nil : i.survey_answers) }
    end
  end

  def _instructors(cat)
    # cat is in [:ta, :prof]
    @category = cat
    @eff_q    = SurveyQuestion.find_by_keyword "#{@category.to_s}_eff".to_sym

    return redirect_to coursesurveys_path, :notice => "Invalid category" unless @category && @eff_q

    @results = []

    Instructor.where("instructors.id IN
                      ( SELECT instructor_id
                        FROM   instructorships
                        INNER JOIN survey_answers
                        ON     survey_answers.instructorship_id = instructorships.id
                        WHERE  survey_answers.survey_question_id = #{@eff_q.id} )").
               order(:last_name).
               each do |i|


#    SurveyAnswer.find(
#    SurveyAnswer.select("survey_answers.id").
#                 where(:survey_question_id => @eff_q.id).
#                 joins("INNER JOIN instructorships ON instructorships.id = survey_answers.instructorship_id").
#                 joins("INNER JOIN instructors     ON instructors.id     = instructorships.instructor_id").
#                 order("instructors.last_name").
#                 limit(20).collect(&:id)).each do |ans|
    #SurveyAnswer.select(:survey_answers=>:id).where(:survey_question_id => @eff_q.id).joins(:instructorship).group("instructorships.instructor_id").limit(20).each do |ans|
      # This gives one survey answer per instructor
      @results << { :instructor => i,
                    :courses    => i.courses,
                    :rating     => i.survey_answers.where(:survey_question_id=>@eff_q.id).average(:mean)
                  }
    end
  end

  def instructors
    _instructors :prof
  end

  def tas
    _instructors :ta
  end

  def instructorsZ
    @category    = (params[:category] == "tas") ? "Teaching Assistants" : "Instructors"
    @eff_q       = SurveyQuestion.find_by_keyword((params[:category] == "tas") ? :ta_eff : :prof_eff)

    @results = []
    Instructor.order(:last_name).each do |instructor|
      ratings = []
      SurveyAnswer.find(:all, 
                        :conditions => { :survey_question_id => @eff_q, :instructor_id => instructor.id }
                       ).each do |answer|
        ratings << answer.mean
      end
      if params[:category] == "tas"
        courses = Course.find(:all,
                   :select => "courses.id",
                   :group =>  "courses.id",
                   :conditions => "klasses_tas.instructor_id = #{instructor.id}",
                   :joins => "INNER JOIN klasses ON klasses.course_id = courses.id INNER JOIN klasses_tas ON klasses_tas.klass_id = klasses.id"
                  )
      else
        courses = Course.find(:all,
                   :select => "courses.id",
                   :group =>  "courses.id",
                   :conditions => "instructors_klasses.instructor_id = #{instructor.id}",
                   :joins => "INNER JOIN klasses ON klasses.course_id = courses.id INNER JOIN instructors_klasses ON instructors_klasses.klass_id = klasses.id"
                  )
      end
      unless ratings.empty?
        if instructor.private
          rating = "private"
        else
          rating = 1.0/ratings.size*ratings.reduce{|x,y| x+y}
        end
        @results << [instructor, courses, rating]
      end
    end
  end

  def instructor
    return redirect_to coursesurveys_instructors_path unless params[:name]

    (last_name, first_name) = params[:name].split(',')
    @instructor = Instructor.find_by_name(first_name, last_name)
    if @instructor.nil? then
      redirect_to coursesurveys_search_path([first_name,last_name].join(' '))
      return
    end
   
    @can_edit = @current_user && authorize_coursesurveys
 
    # Don't do any heavy computation if cache exists
    return if fragment_exist? instructor_cache_path(@instructor)

    @instructed_klasses = []
    @tad_klasses = []

    @undergrad_totals = {}
    @grad_totals = {}

    prof_eff_q  = SurveyQuestion.find_by_keyword(:prof_eff)
    worthwhile_q = SurveyQuestion.find_by_keyword(:worthwhile)
    ta_eff_q  = SurveyQuestion.find_by_keyword(:ta_eff)

    @instructor.klasses.each do |klass|
      effectiveness  = SurveyAnswer.find_by_instructor_klass(@instructor, klass, {:survey_question_id => prof_eff_q.id}).first
      worthwhileness = SurveyAnswer.find_by_instructor_klass(@instructor, klass, {:survey_question_id => worthwhile_q.id}).first

      unless (effectiveness.blank? or worthwhileness.blank?)
        @instructed_klasses << [
          klass.id, 
          @instructor.id, 
          effectiveness.id,
          worthwhileness.id,
        ]

        if klass.course.course_number.to_i < 200 
          totals = @undergrad_totals
        else
          totals = @grad_totals
        end

        totals[klass.course.id] ||= []
        totals[klass.course.id] << [effectiveness.mean, worthwhileness.mean]
#        if totals.has_key? klass.course
#          totals[klass.course.id] << [effectiveness.mean, worthwhileness.mean]
#        else
#          totals[klass.course.id] = [[effectiveness.mean, worthwhileness.mean]]
#        end
      end
    end

    # Aggregate totals
    totals = [@undergrad_totals, @grad_totals]
    total = [0,0] # will end up as [@undergrad_total, @grad_total]
    [0,1].each do |i|
      unless totals[i].empty?
        totals[i].keys.each do |course_id|
          scores = totals[i][course_id]
          count = scores.size
          total_score = scores.reduce{|tuple0, tuple1| [tuple0[0] + tuple1[0], tuple0[1] + tuple1[1]]}
          totals[i][course_id] = total_score.map{|score| score/count}.push count
        end
        total[i] = totals[i].keys.reduce([0, 0, 0]) do |sum, new| 
          (sum_eff, sum_wth, sum_count) = sum
          (new_eff, new_wth, new_count) = totals[i][new]
          [sum_eff + new_eff*new_count, sum_wth + new_wth*new_count, sum_count+new_count]
        end
        (eff, wth, count) = total[i]
        total[i] = [eff/count, wth/count, count] unless count == 0
      end
    end
    @undergrad_total, @grad_total = total


    @instructor.tad_klasses.each do |klass_id|
      effectiveness  = SurveyAnswer.find(:first, :conditions => {:instructor_id=>@instructor.id, :klass_id=>klass_id, :survey_question_id => ta_eff_q.id})
      unless effectiveness.blank?
        @tad_klasses << [
          klass_id, 
          @instructor.id, 
          effectiveness.id,
          nil                # no worthwhileness
        ]
      end
    end
    
    # Unwrap from id to object, for the view
    [@instructed_klasses, @tad_klasses].each do |a|
      a.each do |k|
        k[0] =        Klass.find(k[0])
        k[1] =   Instructor.find(k[1])
        k[2] = SurveyAnswer.find(k[2])
        k[3] = SurveyAnswer.find(k[3]) unless k[3].blank?
      end
    end
    
    temp = {}
    @undergrad_totals.each do |course_id,tuple|
      temp[Course.find(course_id)] = tuple
    end
    @undergrad_totals = temp

    temp = {}
    @grad_totals.each do |course_id,tuple|
      temp[Course.find(course_id)] = tuple
    end
    @grad_totals = temp
  end #instructor

  def editinstructor
    @instructor = Instructor.find_by_id(params[:id].to_i)
    if @instructor.nil?
      redirect_back_or_default coursesurveys_path, :notice => "Error: Couldn't find instructor with id #{params[:id]}."
    end
  end

  def updateinstructor
    @instructor = Instructor.find(params[:id].to_i)
    return redirect_back_or_default coursesurveys_path, :notice => "Error: Couldn't find instructor with id #{params[:id]}." unless @instructor

    return redirect_to coursesurveys_edit_instructor_path(@instructor), :notice => "There was a problem updating the entry for #{@instructor.full_name}: #{@instructor.errors.inspect}" unless @instructor.update_attributes(params[:instructor])

    (@instructor.klasses+@instructor.tad_klasses).each do |k|
      expire_action klass_cache_path k
    end
    return redirect_to surveys_instructor_path(@instructor), :notice => "Successfully updated #{@instructor.full_name}."
  end

  def rating
    @answer = SurveyAnswer.find(params[:id])
    @klass  = @answer.klass
    @course = @klass.course
    @instructor = @answer.instructor
    @results = []
    @frequencies = ActiveSupport::JSON.decode(@answer.frequencies)
    @total_responses = @frequencies.values.reduce{|x,y| x.to_i+y.to_i}
    @mode = @frequencies.values.max # TODO: i think this is wrong and always returns the highest score...
    # Someone who understands statistics, please make sure the following line is correct
    @conf_intrvl = @total_responses > 0 ? 1.96*@answer.deviation/Math.sqrt(@total_responses) : 0
    @can_edit = @current_user && authorize_coursesurveys
  end
  
  def editrating
    @answer = SurveyAnswer.find(params[:id])
    @frequencies = decode_frequencies(@answer.frequencies)
  end
  
  def updaterating
    a = SurveyAnswer.find(params[:id])
    if a.nil? then
        flash[:error] = "Fail. updaterating##{params[:id]}"
    else
        # Hashify
        new_frequencies = decode_frequencies(a.frequencies)
        
        # Remove any rogue values: allow only score values, N/A, and Omit       
        params[:frequencies].each_pair do |key,value|
            key = key.to_i if key.eql?(key.to_i.to_s)
            new_frequencies[key] = value.to_i if ( ["N/A", "Omit"].include?(key) or (1..a.survey_question.max).include?(key) )
        end
        
        # Update fields
        a.frequencies = ActiveSupport::JSON.encode(new_frequencies)
        a.recompute_stats!
        a.save
    end
    redirect_to coursesurveys_rating_path(params[:id])
  end

  def search
    return if strip_params

    @prof_eff_q = SurveyQuestion.find_by_keyword(:prof_eff)
    @ta_eff_q   = SurveyQuestion.find_by_keyword(:ta_eff)

    # Query
    params[:q] = sanitize_query(params[:q]) 

    # Department
    unless params[:dept].blank?
      @dept = Department.find_by_nice_abbr(params[:dept].upcase)
      params[:dept] = (@dept ? @dept.abbr : nil)
    end

    @results = {} # [instructor, courses, rating]

    if $SUNSPOT_ENABLED
      # Search courses
      @results[:courses] = Course.search do
        with(:department_id, @dept.id) if @dept
        with(:invalid, false)

        keywords params[:q] unless params[:q].blank?

        order_by :score, :desc
        order_by(:department_id, :desc) unless @dept    # hehe put CS results on top
        order_by :course_number, :asc
      end

      # Search instructors
      @results[:instructors] = Instructor.search do
        keywords params[:q] unless params[:q].blank?
      end
    else
      # Solr isn't started, hack together some results
      logger.warn "Solr isn't started, falling back to lame search"

      str = "%#{params[:q]}%"
      [:courses, :instructors].each do |k|
        @results[k] = FakeSearch.new
      end

      @results[:courses].results = Course.find(:all, :conditions => ['description LIKE ? OR name LIKE ? OR (prefix||course_number||suffix) LIKE ?', str, str, str])
      @results[:instructors].results = Instructor.find(:all, :select=>[:id,:first_name,:last_name,:private,:title], :conditions => ["(first_name||' '||last_name) LIKE ?", str])

      flash[:notice] = "Solr isn't started, so your results are probably lacking." if RAILS_ENV.eql?('development')
    end

    # redirect if only one result
    redirect_to surveys_instructor_path(@results[:instructors].results.first) if @results[:instructors].results.length == 1 && @results[:courses].results.empty?
    redirect_to surveys_course_path(@results[:courses].results.first) if @results[:courses].results.length == 1 && @results[:instructors].results.empty?

end

##  def search_BY_SQL
##    @prof_eff_q = SurveyQuestion.find_by_keyword(:prof_eff)
##    @ta_eff_q   = SurveyQuestion.find_by_keyword(:ta_eff)
##    @eff_q = @prof_eff_q
##    query = params[:query] || ""
##    query.upcase!
##
##    # If course abbr format:
##    if %w[CS EE].include? query[0..1].upcase
##      (dept_abbr, prefix, number, suffix) = params[:query].match(
##        /((?:CS)|(?:EE))\s*([a-zA-Z]*)([0-9]*)([a-zA-Z]*)/)[1..-1]
##      dept = Department.find_by_nice_abbr(dept_abbr)
##      course = Course.find(:first, :conditions => {:department_id => dept.id, :prefix => prefix, :course_number => number, :suffix => suffix})
##      redirect_to :action => :course, :dept_abbr => course.dept_abbr, :short_name => course.full_course_number
##    end
##
##    # Else try finding instructor
##    @results = []
##    name_query = params[:query].gsub(/\*/, '%').downcase
##    instructors = Instructor.find(:all, :conditions => ["(lower(last_name) LIKE ?) OR (lower(first_name) LIKE ?)", name_query, name_query]
##                   )
##    if instructors.size == 1
##      instructor = instructors.first
##      redirect_to :action => :instructor, :name => instructor.last_name+","+instructor.first_name
##    end
##
##    instructors.each do |instructor|
##      ratings = []
##      SurveyAnswer.find(:all, 
##                        :conditions => { :survey_question_id => [@prof_eff_q,@ta_eff_q], :instructor_id => instructor.id }
##                       ).each do |answer|
##        ratings << answer.mean
##      end
##      courses = Course.find(:all,
##                   :select => "courses.id",
##                   :group =>  "courses.id",
##                   :conditions => "klasses_tas.instructor_id = #{instructor.id}",
##                   :joins => "INNER JOIN klasses ON klasses.course_id = courses.id INNER JOIN klasses_tas ON klasses_tas.klass_id = klasses.id"
##                  ) + 
##                  Course.find(:all,
##                   :select => "courses.id",
##                   :group =>  "courses.id",
##                   :conditions => "instructors_klasses.instructor_id = #{instructor.id}",
##                   :joins => "INNER JOIN klasses ON klasses.course_id = courses.id INNER JOIN instructors_klasses ON instructors_klasses.klass_id = klasses.id"
##                  )
##      unless ratings.empty?
##        if instructor.private
##          rating = "private"
##        else
##          rating = 1.0/ratings.size*ratings.reduce{|x,y| x+y}
##        end
##        @results << [instructor, courses, rating]
##      end
##    end
##  end

  def show_searcharea
    @show_searcharea = true
  end

  private
  def klass_cache_path(k)
    unless k.is_a? Klass
      k = params_to_klass k
    end
    p = surveys_klass_path k
    p
  end

  def params_to_klass(parms)
    return nil unless @course = Course.find_by_short_name(parms[:dept_abbr], parms[:short_name])
    puts Klass.semester_code_from_s parms[:semester]
    return nil unless sem = Klass.semester_code_from_s( parms[:semester] )

    @klass = Klass.where(:semester => sem, :course_id => @course.id)
    @klass = @klass.where(:section => params[:section].to_i) if params[:section].present? && params[:section].is_int?
    return @klass = @klass.order('section ASC').limit(1).first
  end

end
