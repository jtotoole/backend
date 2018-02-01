use strict;
use warnings;
use utf8;

use Modern::Perl '2015';
use MediaWords::CommonLibs;

use Test::More;

use MediaWords::Test::API;
use MediaWords::Test::DB;
use MediaWords::Test::Solr;
use MediaWords::Test::Supervisor;

use Catalyst::Test 'MediaWords';
use Readonly;
use MediaWords::Controller::Api::V2::Topics;
use MediaWords::DBI::Auth::Roles;
use MediaWords::Test::API;
use MediaWords::Test::DB;

Readonly my $NUM_MEDIA            => 5;
Readonly my $NUM_FEEDS_PER_MEDIUM => 2;
Readonly my $NUM_STORIES_PER_FEED => 10;

sub test_generate_fetch_word2vec_model($)
{
    my $db = shift;

    my $topic = MediaWords::Test::DB::create_test_topic( $db, 'test_generate_word2vec_model' );
    my $topics_id = $topic->{ topics_id };

    $db->query(
        <<SQL,
        UPDATE topics
        SET is_public = 't'
        WHERE topics_id = ?
SQL
        $topics_id
    );

    $db->query(
        <<SQL,
        INSERT INTO topic_stories (topics_id, stories_id)
        SELECT ?, stories_id FROM stories
SQL
        $topics_id
    );

    my $snapshots_id = $db->query(
        <<SQL,
        INSERT INTO snapshots (topics_id, snapshot_date, start_date, end_date)
        VALUES (?, NOW(), NOW(), NOW())
        RETURNING snapshots_id
SQL
        $topics_id
    )->flat->[ 0 ];

    $db->query(
        <<SQL,
        INSERT INTO snap.stories (snapshots_id, media_id, stories_id, url, guid, title, publish_date, collect_date)
        SELECT ?, media_id, stories_id, url, guid, title, publish_date, collect_date FROM stories
SQL
        $snapshots_id
    );

    # Test that no models exist for snapshot
    {
        # No snapshots/single/<snapshots_id> available at the moment
        my $fetched_snapshots = test_get( "/api/v2/topics/$topics_id/snapshots/list" );

        my $found_snapshot = undef;
        for my $snapshot ( @{ $fetched_snapshots->{ snapshots } } )
        {
            if ( $snapshot->{ snapshots_id } == $snapshots_id )
            {
                $found_snapshot = $snapshot;
                last;
            }
        }

        ok( $found_snapshot );
        ok( $found_snapshot->{ word2vec_models } );
        is( ref $found_snapshot->{ word2vec_models }, ref( [] ) );
        is( scalar( @{ $found_snapshot->{ word2vec_models } } ), 0 );
    }

    # Add model generation job
    test_get( "/api/v2/topics/$topics_id/snapshots/$snapshots_id/generate_word2vec_model" );

    # Wait for model to appear
    my $found_models_id = undef;
    for ( my $retry = 1 ; $retry <= 10 ; ++$retry )
    {
        INFO "Trying to fetch generated snapshot model for $retry time...";

        # No snapshots/single/<snapshots_id> available at the moment
        my $fetched_snapshots = test_get( "/api/v2/topics/$topics_id/snapshots/list" );

        my $found_snapshot = undef;
        for my $snapshot ( @{ $fetched_snapshots->{ snapshots } } )
        {
            if ( $snapshot->{ snapshots_id } == $snapshots_id )
            {
                $found_snapshot = $snapshot;
                last;
            }
        }

        ok( $found_snapshot );
        if ( scalar( @{ $found_snapshot->{ word2vec_models } } ) > 0 )
        {
            $found_models_id = $found_snapshot->{ word2vec_models }->[ 0 ]->{ models_id };
            last;
        }

        INFO "Model not found, will retry shortly";
        sleep( 1 );
    }

    ok( defined $found_models_id, "Model's ID was not found after all of the retries" );

    # Try fetching the model
    my $path = "/api/v2/topics/$topics_id/snapshots/$snapshots_id/word2vec_model/$found_models_id?key=" .
      MediaWords::Test::API::get_test_api_key();
    my $response = request( $path );    # Catalyst::Test::request()
    ok( $response->is_success );

    my $model_data = $response->decoded_content;
    ok( defined $model_data );

    my $model_data_length = length( $model_data );
    INFO "Model data length: $model_data_length";
    ok( $model_data_length > 0 );
}

sub test_topics
{
    my ( $db ) = @_;

    my $media = MediaWords::Test::DB::create_test_story_stack_numerated( $db, $NUM_MEDIA, $NUM_FEEDS_PER_MEDIUM,
        $NUM_STORIES_PER_FEED );

    MediaWords::Test::DB::add_content_to_test_story_stack( $db, $media );

    MediaWords::Test::Solr::setup_test_index( $db );

    MediaWords::Test::API::setup_test_api_key( $db );

    test_generate_fetch_word2vec_model( $db );
}

sub main
{
    MediaWords::Test::Supervisor::test_with_supervisor(    #
        \&test_topics,                                     #
        [                                                  #
            'solr_standalone',                             #
            'job_broker:rabbitmq',                         #
            'word2vec_generate_snapshot_model',            #
        ]                                                  #
    );

    done_testing();
}

main();
