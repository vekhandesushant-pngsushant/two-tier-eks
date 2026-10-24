-- Database & user are created by MYSQL_DATABASE / MYSQL_USER env vars.
-- Fakt table banvaaycha ahe.
CREATE TABLE IF NOT EXISTS tasks (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO tasks (title) VALUES ('Welcome! Deployed via Jenkins to EKS'), ('आपले स्वागत आहे!');
