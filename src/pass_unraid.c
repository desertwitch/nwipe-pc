#define _POSIX_C_SOURCE 200809L
#include "pass_internal.h"

int nwipe_unraid_signature( nwipe_context_t* c )
{
    ssize_t r;
    unsigned char* mbr;

    u32 max_mbr_blocks = 0xFFFFFFFF;
    u32 start_sector = 64;
    u32 partition_size;
    u32 size1 = 0;
    u32 size2 = 0;

    c->pass_done = 0; /* Reset pass byte counter */

    if( c->device_io_block_size < 512 )
    {
        nwipe_log(
            NWIPE_LOG_FATAL, "Device block size too small for Unraid preclear signature on '%s'", c->device_name );

        return -1;
    }

    u64 disk_blocks_512 = c->device_size / 512; /* for MBR calculations */
    if( disk_blocks_512 >= max_mbr_blocks )
    {
        /* Disk larger than 2TB */
        size1 = 0x00020000;
        size2 = 0xFFFFFF00;
        start_sector = 1;
        partition_size = max_mbr_blocks;
    }
    else
    {
        if( disk_blocks_512 <= start_sector )
        {
            nwipe_log( NWIPE_LOG_FATAL, "Device too small for Unraid preclear signature on '%s'", c->device_name );

            return -1;
        }
        /* Disk smaller than 2TB */
        partition_size = disk_blocks_512 - start_sector;
    }

    mbr = (unsigned char*) nwipe_alloc_io_buffer( c, c->device_io_block_size, 1, "unraid_signature mbr" );
    if( !mbr )
    {
        nwipe_perror( errno, __FUNCTION__, "nwipe_alloc_io_buffer" );
        nwipe_log( NWIPE_LOG_FATAL, "Unable to allocate buffers" );

        return -1;
    }

    mbr[446] = size1 & 0xFF;
    mbr[447] = ( size1 >> 8 ) & 0xFF;
    mbr[448] = ( size1 >> 16 ) & 0xFF;
    mbr[449] = ( size1 >> 24 ) & 0xFF;

    mbr[450] = size2 & 0xFF;
    mbr[451] = ( size2 >> 8 ) & 0xFF;
    mbr[452] = ( size2 >> 16 ) & 0xFF;
    mbr[453] = ( size2 >> 24 ) & 0xFF;

    mbr[454] = start_sector & 0xFF;
    mbr[455] = ( start_sector >> 8 ) & 0xFF;
    mbr[456] = ( start_sector >> 16 ) & 0xFF;
    mbr[457] = ( start_sector >> 24 ) & 0xFF;

    mbr[458] = partition_size & 0xFF;
    mbr[459] = ( partition_size >> 8 ) & 0xFF;
    mbr[460] = ( partition_size >> 16 ) & 0xFF;
    mbr[461] = ( partition_size >> 24 ) & 0xFF;

    mbr[510] = 0x55;
    mbr[511] = 0xAA;

    if( lseek( c->device_fd, 0, SEEK_SET ) != 0 )
    {
        nwipe_perror( errno, __FUNCTION__, "lseek" );
        nwipe_log( NWIPE_LOG_FATAL, "Unable to seek to start of '%s'", c->device_name );

        free( mbr );

        return -1;
    }

    r = nwipe_write_with_retry( c, c->device_fd, mbr, c->device_io_block_size );
    if( r < 0 || (size_t) r != c->device_io_block_size )
    {
        nwipe_perror( errno, __FUNCTION__, "write" );
        nwipe_log( NWIPE_LOG_FATAL, "Failed writing Unraid preclear signature to '%s'", c->device_name );

        free( mbr );

        return -1;
    }
    c->pass_done += (u64) r;
    c->round_done += (u64) r;

    c->sync_status = 1;
    r = fdatasync( c->device_fd );
    c->sync_status = 0;

    if( r != 0 )
    {
        nwipe_perror( errno, __FUNCTION__, "fdatasync" );
        nwipe_log( NWIPE_LOG_WARNING, "Sync failed on '%s'", c->device_name );
        c->fsyncdata_errors++;
    }

    free( mbr );

    return 0;

} /* nwipe_unraid_signature */

int nwipe_unraid_signature_verify( nwipe_context_t* c )
{
    ssize_t r;
    unsigned char* b;
    unsigned char* expected;

    u32 max_mbr_blocks = 0xFFFFFFFF;
    u32 start_sector = 64;
    u32 partition_size;
    u32 size1 = 0;
    u32 size2 = 0;

    c->pass_done = 0; /* Reset pass byte counter */

    if( c->device_io_block_size < 512 )
    {
        nwipe_log(
            NWIPE_LOG_FATAL, "Device block size too small for Unraid preclear signature on '%s'", c->device_name );

        return -1;
    }

    u64 disk_blocks_512 = c->device_size / 512; /* for MBR calculations */
    if( disk_blocks_512 >= max_mbr_blocks )
    {
        /* Disk larger than 2TB */
        size1 = 0x00020000;
        size2 = 0xFFFFFF00;
        start_sector = 1;
        partition_size = max_mbr_blocks;
    }
    else
    {
        if( disk_blocks_512 <= start_sector )
        {
            nwipe_log( NWIPE_LOG_FATAL, "Device too small for Unraid preclear signature on '%s'", c->device_name );

            return -1;
        }
        /* Disk smaller than 2TB */
        partition_size = disk_blocks_512 - start_sector;
    }

    b = (unsigned char*) nwipe_alloc_io_buffer( c, c->device_io_block_size, 0, "unraid_signature_verify read buffer" );
    expected = (unsigned char*) nwipe_alloc_io_buffer(
        c, c->device_io_block_size, 1, "unraid_signature_verify expected buffer" );

    if( !b || !expected )
    {
        nwipe_perror( errno, __FUNCTION__, "nwipe_alloc_io_buffer" );
        nwipe_log( NWIPE_LOG_FATAL, "Unable to allocate buffers" );

        if( b )
            free( b );
        if( expected )
            free( expected );

        return -1;
    }

    expected[446] = size1 & 0xFF;
    expected[447] = ( size1 >> 8 ) & 0xFF;
    expected[448] = ( size1 >> 16 ) & 0xFF;
    expected[449] = ( size1 >> 24 ) & 0xFF;

    expected[450] = size2 & 0xFF;
    expected[451] = ( size2 >> 8 ) & 0xFF;
    expected[452] = ( size2 >> 16 ) & 0xFF;
    expected[453] = ( size2 >> 24 ) & 0xFF;

    expected[454] = start_sector & 0xFF;
    expected[455] = ( start_sector >> 8 ) & 0xFF;
    expected[456] = ( start_sector >> 16 ) & 0xFF;
    expected[457] = ( start_sector >> 24 ) & 0xFF;

    expected[458] = partition_size & 0xFF;
    expected[459] = ( partition_size >> 8 ) & 0xFF;
    expected[460] = ( partition_size >> 16 ) & 0xFF;
    expected[461] = ( partition_size >> 24 ) & 0xFF;

    expected[510] = 0x55;
    expected[511] = 0xAA;

    if( lseek( c->device_fd, 0, SEEK_SET ) != 0 )
    {
        nwipe_perror( errno, __FUNCTION__, "lseek" );
        nwipe_log( NWIPE_LOG_FATAL, "Unable to seek to start of '%s'", c->device_name );

        free( b );
        free( expected );

        return -1;
    }

    c->sync_status = 1;
    r = fdatasync( c->device_fd );
    c->sync_status = 0;

    if( r != 0 )
    {
        nwipe_perror( errno, __FUNCTION__, "fdatasync" );
        nwipe_log( NWIPE_LOG_WARNING, "Sync failed on '%s'", c->device_name );
        c->fsyncdata_errors++;
    }

    r = nwipe_read_with_retry( c, c->device_fd, b, c->device_io_block_size );
    if( r < 0 || (size_t) r != c->device_io_block_size )
    {
        nwipe_perror( errno, __FUNCTION__, "read" );
        nwipe_log( NWIPE_LOG_FATAL, "Failed to read Unraid preclear signature from '%s'", c->device_name );

        free( b );
        free( expected );

        return -1;
    }
    c->pass_done += (u64) r;
    c->round_done += (u64) r;

    /* We can just compare the entire block, as everything after the signature will be zero */
    if( memcmp( b, expected, c->device_io_block_size ) != 0 )
    {
        nwipe_log( NWIPE_LOG_FATAL, "Unraid preclear signature is invalid on '%s'", c->device_name );
        c->verify_errors += 1;

        free( b );
        free( expected );

        return -1;
    }

    free( b );
    free( expected );

    return 0;

} /* nwipe_unraid_signature_verify */
