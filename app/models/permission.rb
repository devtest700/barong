class Permission < ApplicationRecord
  validates :role, :req_type, :path, presence: true
end
