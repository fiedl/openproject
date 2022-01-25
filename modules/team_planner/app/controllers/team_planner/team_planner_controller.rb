module ::TeamPlanner
  class TeamPlannerController < BaseController
    before_action :find_optional_project
    before_action :redirect_to_first_plan, only: :index
    before_action :authorize

    menu_item :team_planner_view

    def index
      render layout: 'angular/angular'
    end

    current_menu_item :index do
      :team_planner_view
    end

    private

    def redirect_to_first_plan
      return unless @project
      return if team_planner_query_params?

      if (query_id = find_existing_plan)
        redirect_to action: :index, query_id: query_id
      end
    end

    def find_existing_plan
      Query
        .visible(current_user)
        .joins(:views)
        .where('views.type' => 'team_planner')
        .where('queries.project_id' => @project.id)
        .order('queries.name ASC')
        .pick('queries.id')
    end

    def team_planner_query_params?
      params[:query_id] || params[:query_props]
    end
  end
end
