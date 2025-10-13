# trocco-self-hosted-runner-sample

このリポジトリは、TROCCO Self-Hosted Runnerの運用構成を検討するにあたり、各クラウドプラットフォームのコンテナサービスを利用したコンテナ環境の構築や、コンテナ稼働状況をコントロールすることによるコスト最適化の設計例をご紹介するサンプルリポジトリです。

Qiitaで解説記事も公開しているので、そちらも合わせてご確認ください。

# ディレクトリ構成

ディレクトリ構成は以下の通りです。コードを利用する際には、`terraform.tfvars`（Terraformの環境変数）や`.env`（docker-composeの環境変数）を適宜利用するようにしてください。また、あくまで検証のための構成のため、クレデンシャルの取扱いや削除保護など、実運用の際は適切な形で設計をしてください。

```
.
├── aws
│   ├── dependency_graph
│   │   ├── dependency_graph_plan.dot
│   │   ├── dependency_graph_plan.jpg
│   │   ├── dependency_graph.dot
│   │   └── dependency_graph.jpg
│   ├── main.tf
│   ├── Makefile
│   └── README.md
├── azure
│   ├── dependency_graph
│   │   ├── dependency_graph_plan.dot
│   │   ├── dependency_graph_plan.jpg
│   │   ├── dependency_graph.dot
│   │   └── dependency_graph.jpg
│   ├── main.tf
│   ├── Makefile
│   └── README.md
├── docker-compose
│   ├── .gitignore
│   ├── docker-compose.yaml
│   ├── fluent.conf
│   ├── Makefile
│   └── README.md
├── google_cloud
│   ├── dependency_graph
│   │   ├── dependency_graph_plan.dot
│   │   ├── dependency_graph_plan.jpg
│   │   ├── dependency_graph.dot
│   │   └── dependency_graph.jpg
│   ├── src
│   │   ├── main.py
│   │   └── requirements.txt
│   ├── .gitignore
│   ├── api_gateway__cloud_run_functions.tf
│   ├── cloud_scheduler__workflows.tf
│   ├── database.tf
│   ├── main.tf
│   ├── Makefile
│   └── README.md
├── oracle_cloud
│   ├── dependency_graph
│   │   ├── dependency_graph_plan.dot
│   │   ├── dependency_graph_plan.jpg
│   │   ├── dependency_graph.dot
│   │   └── dependency_graph.jpg
│   ├── main.tf
│   ├── Makefile
│   └── README.md
├── scripts
│   └── generate_docs.sh
├── .gitignore
├── .pre-commit-config.yaml
├── README.md
└── terraform-docs.yml
```

## AWS

- ECS Fargateを使ってSelf-Hosted Runnerを最小構成で構築するサンプルコードです。

## Azure

- Container Instances / Container Appsを使ってSelf-Hosted Runnerを最小構成で構築するサンプルコードです。

## docker-compose

- docker-composeを使ってSelf-Hosted Runnerを最小構成で構築するサンプルコードです。
- [「docker-composeでTROCCOのSelf-Hosted Runnerを動かす構成例」](https://qiita.com/SoySoySoyB/items/f68c039bf1a78b8ea26a)の記事も合わせてご確認ください。

## Google Cloud

- `main.tf`がCloud Run Worker Pools / Services / Jobsを使ってSelf-Hosted Runnerを最小構成で構築するサンプルコードです。
- その他のコードは、閉域でのデータ転送のための検証用の設定や、コスト最適化を検討する際の構成例が含まれています。

## Oracle Cloud

- Container Instanceを使ってSelf-Hosted Runnerを最小構成で構築するサンプルコードです。
