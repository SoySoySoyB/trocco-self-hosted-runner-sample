[ ! -f README.md ] && terraform-docs markdown . --output-file README.md
terraform-docs markdown . --output-file README.md --config ../terraform-docs.yml
npx prettier --write README.md
mkdir -p dependency_graph
terraform graph | sed 's/rankdir = "RL"/rankdir = "LR"/g' > "dependency_graph/dependency_graph.dot"
dot "dependency_graph/dependency_graph.dot" -Tjpg -o "dependency_graph/dependency_graph.jpg"
terraform graph -type=plan | sed "s/digraph {/digraph {\n\trankdir = \"LR\"/g" > "dependency_graph/dependency_graph_plan.dot"
dot "dependency_graph/dependency_graph_plan.dot" -Tjpg -o "dependency_graph/dependency_graph_plan.jpg"