output "proxy_ip" {
  description = "public ip of the proxy instance"
  value       = aws_instance.helloworld_proxy.public_ip
}
