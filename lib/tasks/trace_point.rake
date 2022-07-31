require 'ruby-graphviz'

# https://github.com/fiedl/openproject/issues/1

desc "Visualise call stack of /api/v3/work_packages"
task :trace_point => :environment do

  $g = GraphViz.new( :G, :type => :digraph )
  $nodes = {}
  $edges = {}

  def add_node(node_label)
    $nodes[node_label] ||= $g.add_nodes(node_label.gsub(":in", "\n in"))
  end

  def add_edge(first_node_label, second_node_label)
    add_node first_node_label
    add_node second_node_label
    $edges[[first_node_label, second_node_label]] ||= $g.add_edges($nodes[first_node_label], $nodes[second_node_label])
  end

  add_edge "/api/v3/work_packages", "API::V3::WorkPackages::WorkPackagesAPI"
  add_edge "API::V3::WorkPackages::WorkPackagesAPI", "app/services/api/v3/work_package_collection_from_query_params_service.rb:42:in `call'"
  $nodes["/api/v3/work_packages"][:color] = "green"

  tracer_results = []
  tracer = TracePoint.new(:call) do |trace_point|
    if trace_point.defined_class.to_s.include? "Class:WorkPackage("
      call_stack = trace_point.binding.eval("caller") \
          .select { |code_location| code_location.include? "/openproject/" } \
          .select { |code_location| not code_location.include? "bin/rails" } \
          .select { |code_location| not code_location.include? "lib/tasks" } \
          .collect { |code_location| code_location.gsub("/home/dev/openproject/", "") }
      tracer_results << call_stack
      call_stack.each.each_with_index do |code_location, index|
        previous_code_location = call_stack[index - 1] if index > 0
        if previous_code_location
          add_edge(code_location, previous_code_location)
        end
      end
      $nodes[call_stack.first][:color] = 'red'
    end
  end

  tracer.enable { API::V3::WorkPackageCollectionFromQueryParamsService.new(User.first).call({}) }

  $g.output png: "call_stack.png"

end

