//specify the provider

provider "aws"{
	profile = "akshay"
  	region  = "ap-south-1"
}


//generate a SSH key
resource "tls_private_key" "terra_key"{
	algorithm="RSA"
}


//generate a key pair using the SSH key
resource "aws_key_pair" "terra_key_pair"{
	key_name   = "terraform-key"
	public_key = tls_private_key.terra_key.public_key_openssh
}


//create a security group for allowing HTTP and SSH requests
resource "aws_security_group" "http_ssh_group"{
	name        = "allow_http"
	description = "Allow HTTP inbound traffic"

  	ingress{
		description = "HTTP from VPC"
		from_port   = 80
		to_port     = 80
		protocol    = "tcp"
		cidr_blocks = ["0.0.0.0/0"]
	}

	ingress{
		description = "SSH from VPC"
		from_port   = 22
    		to_port = 22
    		protocol    = "tcp"
    		cidr_blocks = ["0.0.0.0/0"]
  	}

  	egress{
 		from_port = 0
		to_port = 0
 		protocol = "-1"
  		cidr_blocks = ["0.0.0.0/0"]
 	}

	tags ={
    		Name = "allow_http_ssh"
  	}
}



//create an EC2 Instance
resource "aws_instance" "akOS"{
	ami = "ami-0447a12f28fddb066"
	instance_type = "t2.micro"
	key_name = aws_key_pair.terra_key_pair.key_name
	security_groups = ["${aws_security_group.http_ssh_group.name}"]
}



//create an EBS Volume
resource "aws_ebs_volume" "ebsVol"{
	availability_zone = aws_instance.akOS.availability_zone
	size = 1
	tags ={
    		Name = "EBS via Terraform"
  	}
}


//attach the above created EBS Volume
resource "aws_volume_attachment" "ebsVolAttach"{
	device_name = "/dev/sdh"
	volume_id   = aws_ebs_volume.ebsVol.id
	instance_id = aws_instance.akOS.id
	force_detach = true
}



//create a S3 Bucket
resource "aws_s3_bucket" "terra_S3"{
	acl = "public-read"
	versioning{
		enabled=true
	}
}


resource "null_resource" "clone-git-repo"{
	provisioner "local-exec" {
		command = "git clone https://github.com/akmak1103/TerraformAutomationSample.git git-repo "
                 }
}


//add an image to the S3 bucket after cloning the repo locally
resource "aws_s3_bucket_object" "image"{
	depends_on = [
		null_resource.clone-git-repo
	]

	bucket = aws_s3_bucket.terra_S3.id
	key = "sample_image"
	source = "git-repo/image.jpg"
	acl = "public-read"
}


//create a CloudFront Distribution using the S3 Bucket
resource "aws_cloudfront_distribution" "terra_s3_distribution"{
	origin{
		domain_name = aws_s3_bucket.terra_S3.bucket_regional_domain_name
		origin_id   = "terra_origin"
	}

	enabled = true
	is_ipv6_enabled = true
	comment = "Image in CloudFront via Terraform"
	default_root_object = "sample_img"

	default_cache_behavior{
    		allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
		cached_methods   = ["GET", "HEAD"]
		target_origin_id = "terra_origin"
		forwarded_values{
			query_string = false
			cookies {
				forward = "none"
			}
		}

		viewer_protocol_policy = "allow-all"
    		min_ttl = 0
		default_ttl = 3600
		max_ttl = 86400
	}

	price_class = "PriceClass_200"
	restrictions{
		geo_restriction{
			restriction_type = "whitelist"
			locations = ["IN"]
		}
	}
	tags ={
    		Environment = "production"
	}
	viewer_certificate{
    		cloudfront_default_certificate = true
	}

	# Cache behavior with precedence 0
	ordered_cache_behavior{
    		path_pattern = "/content/immutable/*"
    		allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    		cached_methods = ["GET", "HEAD", "OPTIONS"]
    		target_origin_id = "terra_origin"
    		forwarded_values{
			query_string = false
			headers      = ["Origin"]
      			cookies{
        				forward = "none"
			}
		}
    		min_ttl = 0
		default_ttl = 86400
		max_ttl = 31536000
		compress = true
		viewer_protocol_policy = "redirect-to-https"
	}

	# Cache behavior with precedence 1
	ordered_cache_behavior{
    		path_pattern = "/content/*"
    		allowed_methods = ["GET", "HEAD", "OPTIONS"]
    		cached_methods = ["GET", "HEAD"]
    		target_origin_id = "terra_origin"
    		forwarded_values{
      			query_string = false
			cookies{
        				forward = "none"
     			}
		}

    		min_ttl = 0
		default_ttl = 3600
		max_ttl = 86400
		compress = true
		viewer_protocol_policy = "redirect-to-https"
	}
}



//configure the instance by downloading all the packages and code
resource "null_resource" "configure_ec2"{
	depends_on = [
		aws_cloudfront_distribution.terra_s3_distribution,
		aws_instance.akOS,
		aws_volume_attachment.ebsVolAttach		
	]

	connection{
		type     = "ssh"
		user = "ec2-user"
		private_key = tls_private_key.terra_key.private_key_pem
		host = aws_instance.akOS.public_ip
	}
	provisioner "remote-exec"{
		inline = [
			"sudo yum install httpd git -y",
			"sudo systemctl start httpd",
			"sudo systemctl enable httpd",
			"sudo mkfs.ext4  /dev/xvdh",
			"sudo mount  /dev/xvdh  /var/www/html",
			"sudo rm -rf /var/www/html/*",
			"sudo git clone https://github.com/akmak1103/TerraformAutomationSample.git /var/www/html/",
			"sudo sed -i 's@image-url@http://${aws_cloudfront_distribution.terra_s3_distribution.domain_name}/${aws_s3_bucket_object.image.key}@g' /var/www/html/index.html",
 			"sudo systemctl restart httpd"
		]
	}
}



//save SSH key
resource "local_file" "save_key"{
	depends_on = [
		null_resource.configure_ec2,
	]
	content = tls_private_key.terra_key.private_key_pem
	filename = "terra_key.pem"
}


resource "null_resource" "savePublicIP"{
	depends_on = [
		null_resource.configure_ec2,
	]
	provisioner "local-exec" {
		command = "echo ${aws_instance.akOS.public_ip} > akOS_public_IP.txt"
                 }
}

resource "null_resource" "startServer"{
	depends_on = [
		null_resource.configure_ec2,
	]
	provisioner "local-exec" {
		command = "start msedge ${aws_instance.akOS.public_ip}"
                 }
}

resource "null_resource" "delete-local-repo"{
	depends_on = [
		null_resource.startServer,
	]
	provisioner "local-exec" {
		command = "rd /s /q git-repo"
                 }
}