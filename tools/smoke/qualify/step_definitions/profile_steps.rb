Given("the profile holds {string} as {string}") do |key, value|
  @profile_values = (@profile_values || {}).merge(key => value)
  values = @profile_values
  grokit_fake(:profile, fetch: ->(wanted) { values[wanted] })
end

Given("the profile holds {string} as the number {int}") do |key, value|
  @profile_values = (@profile_values || {}).merge(key => value)
  values = @profile_values
  grokit_fake(:profile, fetch: ->(wanted) { values[wanted] })
end
