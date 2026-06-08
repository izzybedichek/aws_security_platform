[
  {
    "name": "cb-app",
    "image": "${app_image}",
    "cpu": ${fargate_cpu},
    "memory": ${fargate_memory},
    "networkMode": "awsvpc",
    "environment": [
      { "name": "AWS_REGION",          "value": "${aws_region}" },
      { "name": "PORT",                "value": "${app_port}" },
      { "name": "REPORTS_BUCKET",      "value": "${reports_bucket}" },
      { "name": "METRICS_TABLE",       "value": "${metrics_table}" },
      { "name": "SCANNER_TOKEN_PARAM", "value": "${token_param}" },
      { "name": "SCAN_QUEUE_URL",      "value": "${scan_queue_url}" },
      { "name": "RUN_WORKER",          "value": "${run_worker}" }
    ],
    "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/cb-app",
          "awslogs-region": "${aws_region}",
          "awslogs-stream-prefix": "ecs"
        }
    },
    "portMappings": [
      {
        "containerPort": ${app_port},
        "hostPort": ${app_port}
      }
    ]
  }
]